# syntax=docker/dockerfile:1.4

# Build a fully static herd binary against musl, inside an Alpine container.

FROM docker.io/library/alpine:3.21 AS build

RUN apk add --no-cache build-base git

# Janet stores pointers in double mantissas, so nanboxing supports only
# 47-bit pointers. Emulated amd64 can return 0x0000ffff........ addresses, so
# bit 47 is lost. This causes Janet's boot test to fail before herd is
# compiled. Arm64 needs no help here: janet.h already disables nanboxing for
# it.
#
# So probe the address space rather than the architecture, and only on amd64,
# where a high address is how emulation shows itself: an emulated amd64 build
# drops nanboxing, and one on real x86-64 keeps it. Release builds are
# unchanged, x86-64 running on x86-64.

WORKDIR /src/probe
COPY nanbox-probe.c .
# The janet step below runs this. Building it here keeps that step to one job.
RUN cc -O0 -o /usr/local/bin/nanbox-probe nanbox-probe.c

# Alpine provides neither janet nor jpm, so build both from source. Janet is
# written in plain C, and jpm uses a bootstrap script; building both takes
# about a minute.

WORKDIR /src/janet
# Janet 1.41.2.
ARG JANET_COMMIT=0fea20c82182fe661f75b00a8889d801fe2d79b6
RUN <<'EOF'
set -eu
git init -q .
git remote add origin https://github.com/janet-lang/janet.git
git fetch -q --depth 1 origin "$JANET_COMMIT"
git checkout -q FETCH_HEAD
# janetconf.h already contains the nanboxing switch. make install copies it
# into janet.h, so the interpreter and native module use the same setting.
# uname reports the emulated architecture, which matches the probe's target.
arch=$(uname -m)
if [ "$arch" = x86_64 ] && nanbox-probe; then
    sed -i 's|/\* #define JANET_NO_NANBOX \*/|#define JANET_NO_NANBOX|' \
        src/conf/janetconf.h
    # If janetconf.h changes, nanboxing stays enabled and the boot test fails
    # without explaining why. Check that sed changed the expected line.
    grep -qx '#define JANET_NO_NANBOX' src/conf/janetconf.h
    # On amd64 a high address means the build is emulated. Say so, because
    # the make output below is long.
    rule='!!=================================================================!!'
    msg="$arch: emulated -- nanboxing OFF, address past 2^47"
    printf '\n%s\n!! %-63s !!\n%s\n\n' "$rule" "$msg" "$rule"
fi
make -j"$(nproc)"
make install
EOF

WORKDIR /src/jpm
# jpm 1.2.0.
ARG JPM_COMMIT=907daf191ad3f1cf7e5190ec4f44eb29cd54ba21
RUN <<'EOF'
set -eu
git init -q .
git remote add origin https://github.com/janet-lang/jpm.git
git fetch -q --depth 1 origin "$JPM_COMMIT"
git checkout -q FETCH_HEAD
janet bootstrap.janet
EOF

WORKDIR /src/herd

# Installing the dependencies requires only the lockfile, so editing a source
# file does not send jpm back to the network. The lockfile also pins every
# dependency to a commit, so rebuilding the same tag later compiles the same
# sources.
COPY lockfile.jdn ./
RUN jpm --local load-lockfile

COPY . .

# Declared here rather than at the top: the version changes on every tag, and
# every layer after an ARG is invalidated when its value does.
ARG HERD_VERSION=dev
# jpm passes --lflags to every link it drives, the native module included, so
# project.janet gives that one an empty set to keep -static off a shared
# object. Here it reaches the executable, which is what wants it.
RUN <<'EOF'
set -eu
HERD_VERSION="$HERD_VERSION" jpm --local build --lflags=-static
strip build/herd
EOF

# The tests run in their own stage, so the build used for a release carries no
# files needed only by the tests. jp is the program that runs a filter. The
# filter tests skip themselves when it is absent rather than fail, so they are
# silently skipped here. Podman builds this stage only when it is requested by
# name, so a release build never installs it.
FROM build AS test
RUN apk add --no-cache jp
CMD ["jpm", "--local", "test"]

# The export stage. `-o type=local,dest=build-musl` writes this filesystem and
# nothing else, so build-musl/herd is the only artifact that reaches the host.
FROM scratch
COPY --from=build /src/herd/build/herd /herd

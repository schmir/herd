# syntax=docker/dockerfile:1.4

# Run the test suite inside an Alpine container, on musl rather than the
# host's libc, and on another architecture under emulation. Release binaries
# are not built here: `just cross` builds them with zig cc.

FROM docker.io/library/alpine:3.21

# jp is the program that runs a filter. The filter tests skip themselves when
# it is absent rather than fail, so without it they would pass unexercised.
RUN apk add --no-cache build-base git jp

# Janet stores pointers in double mantissas, so nanboxing supports only
# 47-bit pointers. Emulated amd64 can return 0x0000ffff........ addresses, so
# bit 47 is lost. This causes Janet's boot test to fail before herd is
# compiled. Arm64 needs no help here: janet.h already disables nanboxing for
# it.
#
# So probe the address space rather than the architecture, and only on amd64,
# where a high address is how emulation shows itself: an emulated amd64 build
# drops nanboxing, and one on real x86-64 keeps it.

WORKDIR /src/probe
COPY nanbox-probe.c .
# The janet step below runs this. Building it here keeps that step to one job.
RUN cc -O0 -o /usr/local/bin/nanbox-probe nanbox-probe.c

# Alpine provides neither janet nor jpm, so build both from source. Janet is
# written in plain C, and jpm uses a bootstrap script; building both takes
# about a minute.

WORKDIR /src/janet
# The commit the justfile pins as janet_commit, passed in by its recipes, so
# the tests run on the Janet the release binaries are cross-compiled from.
ARG JANET_COMMIT
RUN <<'EOF'
set -eu
if [ -z "${JANET_COMMIT:-}" ]; then
    echo "JANET_COMMIT is not set; build through just test-podman" >&2
    exit 1
fi
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

RUN jpm --local build
CMD ["jpm", "--local", "test"]

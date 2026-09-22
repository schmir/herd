# syntax=docker/dockerfile:1.4

# Build a fully static herd binary against musl, inside an Alpine container.
#
# Reproduce a release build locally from the repo root:
#   podman build -o type=local,dest=build-musl .
#
# This needs a podman whose parser understands heredocs: podman 5 does, and
# the 4.9.3 that Ubuntu 24.04 packages does not. Without one, every line of a
# heredoc is read as an instruction of its own, and the build stops at the
# first of them.
#
# Only the binary leaves the container. Nothing of the host tree is shared with
# the build, so there is no way for jpm to mistake a glibc artifact for an
# up-to-date musl one and leave a binary for the wrong platform behind.
#
# The result depends on no shared library at all, so one binary runs on any
# Linux distribution regardless of its glibc version.
#
# The steps are ordered so the expensive ones cache: the toolchain is rebuilt
# only when its pinned versions change, the dependency tree only when
# lockfile.jdn does, and a source edit reaches no further back than the build
# itself.

FROM docker.io/library/alpine:3.21 AS build

RUN apk add --no-cache build-base git

# Janet stores pointers in double mantissas, so nanboxing supports only
# 47-bit pointers. Real x86-64 Linux meets this limit. QEMU amd64 on arm64
# and native arm64 can return 0x0000ffff........ addresses, so bit 47 is lost.
# This causes Janet's boot test to fail before herd is compiled. arm64 already
# disables nanboxing in janet.h.
#
# Probe the address space, not the architecture. Emulated amd64 and native
# arm64 need nanboxing disabled. Real x86-64 keeps it enabled.
#
# Release builds are unchanged: x86-64 runs on x86-64 and arm64 runs on arm64.
# The probe also lets amd64 builds run on arm64 hosts.
#
# Run the probe before cloning Janet. It needs only the compiler and writes its
# result to /tmp/use-nanbox. Bind the source for this step so it does not add a
# layer; COPY . . runs later and would be too late.
RUN --mount=type=bind,source=nanbox-probe.c,target=/tmp/nanbox-probe.c <<'EOF'
set -eu
cc -O0 -o /tmp/nanbox-probe /tmp/nanbox-probe.c
# Print the result clearly because the compiler output is long.
rule='!!=================================================================!!'
banner() { printf '\n%s\n!! %-63s !!\n%s\n\n' "$rule" "$1" "$rule"; }
# uname reports the emulated architecture, which matches the probe's target.
arch=$(uname -m)
if /tmp/nanbox-probe; then
    banner "$arch: nanboxing OFF -- an allocation reached past 2^47"
    echo no > /tmp/use-nanbox
else
    banner "$arch: nanboxing ON -- every allocation stayed under 2^47"
    echo yes > /tmp/use-nanbox
fi
rm -f /tmp/nanbox-probe
EOF

# Alpine packages neither janet nor jpm, so build both from source. They are
# plain C and a bootstrap script; this takes about a minute, once.
# Both are fetched by asking for one commit, rather than for a tag or for an
# archive GitHub generates on request. A commit id is a hash of the tree it
# names, so the server has no say in what a build compiles: this is the same
# source every time, whatever later becomes of the tag it came from.
#
# Janet 1.41.2.
ARG JANET_COMMIT=0fea20c82182fe661f75b00a8889d801fe2d79b6
RUN <<'EOF'
set -eu
git init -q /tmp/janet
git -C /tmp/janet remote add origin https://github.com/janet-lang/janet.git
git -C /tmp/janet fetch -q --depth 1 origin "$JANET_COMMIT"
git -C /tmp/janet checkout -q FETCH_HEAD
# janetconf.h already contains the nanboxing switch. make install copies it
# into janet.h, so the interpreter and native module use the same setting.
if [ "$(cat /tmp/use-nanbox)" = no ]; then
    sed -i 's|/\* #define JANET_NO_NANBOX \*/|#define JANET_NO_NANBOX|' \
        /tmp/janet/src/conf/janetconf.h
    # If janetconf.h changes, nanboxing stays enabled and the boot test fails
    # without explaining why. Check that sed changed the expected line.
    grep -qx '#define JANET_NO_NANBOX' /tmp/janet/src/conf/janetconf.h
fi
make -C /tmp/janet -j"$(nproc)"
make -C /tmp/janet install
rm -rf /tmp/janet
EOF

# jpm 1.2.0.
ARG JPM_COMMIT=907daf191ad3f1cf7e5190ec4f44eb29cd54ba21
RUN <<'EOF'
set -eu
git init -q /tmp/jpm
git -C /tmp/jpm remote add origin https://github.com/janet-lang/jpm.git
git -C /tmp/jpm fetch -q --depth 1 origin "$JPM_COMMIT"
git -C /tmp/jpm checkout -q FETCH_HEAD
cd /tmp/jpm
janet bootstrap.janet
rm -rf /tmp/jpm
EOF

WORKDIR /src

# Installing the dependencies needs nothing but the lockfile, so editing a
# source file does not send jpm back to the network. The lockfile also pins
# every dependency to a commit, so a release built today and the same tag
# rebuilt later compile the same sources.
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

# The tests run from a stage of their own, so the build a release is cut from
# carries nothing only they need. jp is the program a filter runs, and the
# filter tests skip themselves when it is absent rather than fail, which is
# how they went quietly unrun here. Podman builds this stage only when it is
# asked for by name, so a release build never installs it.
FROM build AS test
RUN apk add --no-cache jp
CMD ["jpm", "--local", "test"]

# The export stage. `-o type=local,dest=build-musl` writes this filesystem and
# nothing else, so build-musl/herd is the only artifact that reaches the host.
FROM scratch
COPY --from=build /src/build/herd /herd

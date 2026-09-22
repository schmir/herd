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

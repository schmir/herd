# Build a fully static herd binary against musl, inside an Alpine container.
#
# Reproduce a release build locally from the repo root:
#   podman build -o type=local,dest=build-musl .
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
# project.janet does, and a source edit reaches no further back than the build
# itself.

FROM docker.io/library/alpine:3.21 AS build

RUN apk add --no-cache build-base git curl

# Alpine packages neither janet nor jpm, so build both from source. They are
# plain C and a bootstrap script; this takes about a minute, once.
ARG JANET_VERSION=1.41.2
RUN curl -fsSL "https://github.com/janet-lang/janet/archive/refs/tags/v${JANET_VERSION}.tar.gz" \
      | tar xz -C /tmp \
    && make -C "/tmp/janet-${JANET_VERSION}" -j"$(nproc)" \
    && make -C "/tmp/janet-${JANET_VERSION}" install \
    && rm -rf "/tmp/janet-${JANET_VERSION}"

ARG JPM_VERSION=v1.2.0
RUN git clone --depth 1 --branch "$JPM_VERSION" https://github.com/janet-lang/jpm.git /tmp/jpm \
    && cd /tmp/jpm \
    && janet bootstrap.janet \
    && rm -rf /tmp/jpm

WORKDIR /src

# Resolving the dependencies needs nothing but their declaration, so editing a
# source file does not send jpm back to the network.
COPY project.janet ./
RUN jpm --local deps

COPY . .

# Declared here rather than at the top: the version changes on every tag, and
# every layer after an ARG is invalidated when its value does.
ARG HERD_VERSION=dev
# jpm's default :lflags is empty, so this only adds -static to the final link.
RUN HERD_VERSION="$HERD_VERSION" jpm --local build --lflags=-static \
    && strip build/herd

# The export stage. `-o type=local,dest=build-musl` writes this filesystem and
# nothing else, so build-musl/herd is the only artifact that reaches the host.
FROM scratch
COPY --from=build /src/build/herd /herd

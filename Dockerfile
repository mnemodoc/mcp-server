###########
# CRYSTAL #
###########

FROM alpine:3.23 AS crystal

RUN apk add --update --no-cache \
  bash \
  make \
  crystal=~1.18 \
  shards \
  gc-dev \
  gc-static \
  gettext \
  git \
  libxml2-dev \
  libxml2-static \
  openssl-dev \
  openssl-libs-static \
  pcre2-dev \
  pcre2-static \
  xz-dev \
  xz-static \
  yaml-dev \
  yaml-static \
  zlib-dev \
  zlib-static \
  sqlite-dev \
  sqlite-static \
  upx

FROM crystal AS build-binary-file

ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT

ENV \
  TARGETPLATFORM=${TARGETPLATFORM} \
  TARGETOS=${TARGETOS} \
  TARGETARCH=${TARGETARCH} \
  TARGETVARIANT=${TARGETVARIANT}

WORKDIR /build
COPY .git/ /build/.git/
COPY shard.yml shard.lock /build/
COPY LICENSE licenses.manifest /build/
COPY licenses-spdx/ /build/licenses-spdx/
COPY scripts/ /build/scripts/
COPY Makefile.release /build/Makefile
COPY vendor/ /build/vendor/
COPY ext/ /build/ext/
COPY src/ /build/src/
RUN mkdir /build/bin

RUN make release

FROM scratch AS binary-file
ARG TARGETOS
ARG TARGETARCH
COPY --from=build-binary-file /build/bin/mnemodoc-server-${TARGETOS}-${TARGETARCH} /

FROM gcr.io/distroless/static-debian12 AS docker-image

ARG TARGETOS
ARG TARGETARCH

COPY --from=build-binary-file /build/bin/mnemodoc-server-${TARGETOS}-${TARGETARCH} /usr/bin/mnemodoc-server

USER nonroot
ENV USER=nonroot
ENV HOME=/home/nonroot
WORKDIR /home/nonroot
ENTRYPOINT ["mnemodoc-server"]

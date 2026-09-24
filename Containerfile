# bump FEDORA_VERSION when aurora's stable stream moves to the next fedora release
ARG FEDORA_VERSION=44
ARG BASE_TAG=stable

FROM scratch AS ctx
COPY build_files /

FROM ghcr.io/ublue-os/akmods:coreos-stable-${FEDORA_VERSION} AS akmods
FROM ghcr.io/ublue-os/akmods-zfs:coreos-stable-${FEDORA_VERSION} AS akmods-zfs

FROM ghcr.io/ublue-os/aurora:${BASE_TAG}

ARG FEDORA_VERSION
ARG BASE_DIGEST=unrecorded

LABEL dev.yellowhat.base-image="ghcr.io/ublue-os/aurora"
LABEL dev.yellowhat.base-digest="${BASE_DIGEST}"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods,src=/kernel-rpms,dst=/tmp/kernel-rpms \
    --mount=type=bind,from=akmods-zfs,src=/rpms/kmods/zfs,dst=/tmp/rpms/kmods/zfs \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/var/log \
    FEDORA_VERSION=${FEDORA_VERSION} /ctx/zfs.sh

RUN bootc container lint

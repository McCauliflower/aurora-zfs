# bump FEDORA_VERSION when aurora's stable stream moves to the next fedora release
ARG FEDORA_VERSION=44
ARG BASE_REF=ghcr.io/ublue-os/aurora:stable
ARG AKMODS_REF=ghcr.io/ublue-os/akmods:coreos-stable-${FEDORA_VERSION}
ARG AKMODS_ZFS_REF=ghcr.io/ublue-os/akmods-zfs:coreos-stable-${FEDORA_VERSION}

FROM scratch AS ctx
COPY build_files /

FROM ${AKMODS_REF} AS akmods
FROM ${AKMODS_ZFS_REF} AS akmods-zfs

FROM ${BASE_REF}

ARG FEDORA_VERSION
ARG BASE_DIGEST=unrecorded
ARG AKMODS_NAME=unrecorded
ARG AKMODS_DIGEST=unrecorded
ARG AKMODS_VERSION=unrecorded
ARG AKMODS_ZFS_NAME=unrecorded
ARG AKMODS_ZFS_DIGEST=unrecorded
ARG AKMODS_ZFS_VERSION=unrecorded
ARG ZFS_VERSION=unrecorded
ARG REVISION=unrecorded

LABEL org.opencontainers.image.base.name="ghcr.io/ublue-os/aurora"
LABEL org.opencontainers.image.base.digest="${BASE_DIGEST}"
LABEL aurora-zfs.akmods.name="${AKMODS_NAME}"
LABEL aurora-zfs.akmods.digest="${AKMODS_DIGEST}"
LABEL aurora-zfs.akmods.version="${AKMODS_VERSION}"
LABEL aurora-zfs.akmods-zfs.name="${AKMODS_ZFS_NAME}"
LABEL aurora-zfs.akmods-zfs.digest="${AKMODS_ZFS_DIGEST}"
LABEL aurora-zfs.akmods-zfs.version="${AKMODS_ZFS_VERSION}"
LABEL aurora-zfs.zfs.version="${ZFS_VERSION}"
LABEL org.opencontainers.image.revision="${REVISION}"
LABEL org.opencontainers.image.source="https://github.com/McCauliflower/aurora-zfs"
LABEL org.opencontainers.image.url="https://github.com/McCauliflower/aurora-zfs"
LABEL org.opencontainers.image.title="aurora-zfs"
LABEL org.opencontainers.image.description="Aurora with ZFS re-added"

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods,src=/kernel-rpms,dst=/tmp/kernel-rpms \
    --mount=type=bind,from=akmods-zfs,src=/rpms/kmods/zfs,dst=/tmp/rpms/kmods/zfs \
    --mount=type=cache,dst=/var/cache \
    --mount=type=tmpfs,dst=/var/log \
    FEDORA_VERSION=${FEDORA_VERSION} /ctx/zfs.sh

RUN bootc container lint

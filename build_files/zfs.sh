#!/usr/bin/bash

set -eoux pipefail

. /etc/os-release
if [[ "${VERSION_ID}" != "${FEDORA_VERSION}" ]]; then
    echo "FATAL: base image is fedora ${VERSION_ID} but the akmods tags target ${FEDORA_VERSION}." >&2
    echo "Bump FEDORA_VERSION in the Containerfile and rebuild." >&2
    exit 1
fi

AKMODS_KERNEL="$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' /tmp/kernel-rpms/kernel-core-*.rpm | tail -1)"
BASE_KERNEL="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1)"

if ! compgen -G "/tmp/rpms/kmods/zfs/kmod-zfs-${AKMODS_KERNEL}-*.rpm" >/dev/null; then
    echo "FATAL: akmods-zfs has no module built for kernel ${AKMODS_KERNEL}." >&2
    ls -1 /tmp/rpms/kmods/zfs/ >&2 || true
    exit 1
fi

if [[ "${AKMODS_KERNEL}" != "${BASE_KERNEL}" ]]; then
    for pkg in kernel kernel{-core,-modules,-modules-core,-modules-extra}; do
        rpm --erase "${pkg}" --nodeps || true
    done
    rm -rf /usr/lib/modules
    dnf5 -y install \
        /tmp/kernel-rpms/kernel-[0-9]*.rpm \
        /tmp/kernel-rpms/kernel-core-*.rpm \
        /tmp/kernel-rpms/kernel-modules-*.rpm
fi

KERNEL="${AKMODS_KERNEL}"

dnf5 versionlock add kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra || true

mapfile -t PRESENT < <(rpm -qa --qf '%{NAME}\n' \
    'kmod-zfs*' 'zfs' 'zfs-*' 'libzfs*' 'libzpool*' 'libnvpair*' 'libuutil*' 'python3-pyzfs' \
    2>/dev/null | sort -u)
if [[ ${#PRESENT[@]} -gt 0 ]]; then
    rpm --erase --nodeps "${PRESENT[@]}"
fi

ZFS_RPMS=(
    /tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"-*.rpm
    /tmp/rpms/kmods/zfs/libnvpair[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libuutil[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libzfs[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libzpool[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/python3-pyzfs-*.rpm
    /tmp/rpms/kmods/zfs/zfs-*.rpm
    pv
)

dnf5 -y install "${ZFS_RPMS[@]}"

depmod -a -v "${KERNEL}"
echo "zfs" >/usr/lib/modules-load.d/zfs.conf

modinfo -k "${KERNEL}" zfs >/dev/null

dnf5 versionlock clear
dnf5 clean all
rm -rf /var/lib/dnf/repos /var/log/dnf5.log /run/dnf /var/cache/dnf

#!/usr/bin/bash
# Prints the ZFS version packaged in an akmods-zfs image, e.g. 2.4.4-1.fc44.
# The image's own version label only carries the kernel version.

set -euo pipefail

ref="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

skopeo copy -q "docker://${ref}" "dir:${tmp}"

mapfile -t found < <(
    for blob in "${tmp}"/*; do
        tar -tf "${blob}" 2>/dev/null || true
    done | sed -nE 's#^(\./)?rpms/kmods/zfs/zfs-([0-9][^/]*)\.x86_64\.rpm$#\2#p' | sort -u
)

if (( ${#found[@]} != 1 )) || [[ ! "${found[0]}" =~ ^[0-9][A-Za-z0-9._+-]*$ ]]; then
    echo "expected exactly one zfs version in ${ref}, found: ${found[*]:-none}" >&2
    exit 1
fi

echo "${found[0]}"

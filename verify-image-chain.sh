#!/usr/bin/bash

set -uo pipefail

COSIGN=/usr/local/bin/cosign
SKOPEO=/usr/bin/skopeo
RPMOSTREE=/usr/bin/rpm-ostree
PYTHON=/usr/bin/python3

UBLUE_KEYS=(/usr/lib/pki/containers/ublue-os.pub /usr/lib/pki/containers/ublue-os-backup.pub)
OWN_KEY=/etc/pki/containers/aurora-zfs.pub

status=0
fail() { echo "FAIL: $*" >&2; status=2; }
ok()   { echo "ok   : $*"; }

if [[ ${EUID} -eq 0 ]]; then
    echo "refusing to run as root: this parses data fetched from a remote registry" >&2
    exit 64
fi

for tool in "${COSIGN}" "${SKOPEO}" "${RPMOSTREE}" "${PYTHON}"; do
    if [[ ! -x "${tool}" ]]; then
        fail "missing ${tool}"
        continue
    fi
    read -r owner mode < <(stat -c '%U %a' "${tool}")
    [[ "${owner}" == root ]] || fail "${tool} is owned by ${owner}, not root - it can be replaced without root"
    [[ "${mode}" =~ [0-7][0-57][0-57]$ ]] || fail "${tool} is group/world writable (mode ${mode})"
done
(( status == 0 )) || { echo "toolchain integrity check failed; not proceeding" >&2; exit "${status}"; }
ok "toolchain is root-owned and not user-writable"

ref="$("${RPMOSTREE}" status --json | "${PYTHON}" -c '
import json,sys
b=[d for d in json.load(sys.stdin)["deployments"] if d.get("booted")][0]
print((b.get("container-image-reference") or "").split("docker://")[-1])
')"
[[ -z "${ref}" ]] && { fail "not running a container image"; exit 2; }
echo "booted image : ${ref}"

meta="$("${SKOPEO}" inspect "docker://${ref}" 2>/dev/null)" || { fail "cannot inspect ${ref}"; exit 2; }
read -r base_image base_digest < <("${PYTHON}" -c '
import json,sys
l=json.load(sys.stdin).get("Labels") or {}
print(l.get("org.opencontainers.image.base.name","") or "-", l.get("org.opencontainers.image.base.digest","") or "-")
' <<<"${meta}")

if [[ "${base_digest}" == "-" || "${base_digest}" == "unrecorded" ]]; then
    fail "image does not record which base it was built from"
else
    echo "built from   : ${base_image}@${base_digest}"
fi

if [[ -f "${OWN_KEY}" ]]; then
    "${COSIGN}" verify --key "${OWN_KEY}" "${ref}" >/dev/null 2>&1 \
        && ok "own signature valid" \
        || fail "own signature INVALID for ${ref}"
else
    fail "own public key missing at ${OWN_KEY}"
fi

if [[ "${base_digest}" != "-" && "${base_digest}" != "unrecorded" ]]; then
    verified=0
    for k in "${UBLUE_KEYS[@]}"; do
        [[ -f "$k" ]] || continue
        if "${COSIGN}" verify --key "$k" "${base_image}@${base_digest}" >/dev/null 2>&1; then
            ok "base image signed by ublue ($(basename "$k"))"
            verified=1
            break
        fi
    done
    (( verified )) || fail "base ${base_image}@${base_digest} is NOT signed by any known ublue key"
fi

(( status == 0 )) && echo "chain OK"
exit "${status}"

#!/usr/bin/bash

set -uo pipefail

COSIGN=/usr/local/bin/cosign
SKOPEO=/usr/bin/skopeo
RPMOSTREE=/usr/bin/rpm-ostree
PYTHON=/usr/bin/python3
SYSTEMD_CAT=/usr/bin/systemd-cat
NOTIFY_SEND=/usr/bin/notify-send

UBLUE_KEYS=(/usr/lib/pki/containers/ublue-os.pub /usr/lib/pki/containers/ublue-os-backup.pub)
OWN_KEY=/etc/pki/containers/aurora-zfs.pub

status=0
fail() { echo "FAIL: $*" >&2; status=2; }
ok()   { echo "ok   : $*"; }

notify() {
    local urgency="$1" title="$2" body="$3"
    local icon="/usr/local/share/aurora-zfs/icons/green.png"
    [[ "${urgency}" == crit ]] && icon="/usr/local/share/aurora-zfs/icons/red.png"
    echo "${title}: ${body}"
    "${SYSTEMD_CAT}" -t image-chain -p "${urgency}" <<<"${title}: ${body}"
    [[ -x "${NOTIFY_SEND}" ]] && \
        "${NOTIFY_SEND}" -a "Aurora ZFS Image Chain" \
            -u "$([[ ${urgency} == crit ]] && echo critical || echo normal)" \
            -t 0 -i "${icon}" "${title}" "${body}" 2>/dev/null
}

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

read -r ref repo digest version < <("${RPMOSTREE}" status --json | "${PYTHON}" -c '
import json,sys
b=[d for d in json.load(sys.stdin)["deployments"] if d.get("booted")][0]
ref=(b.get("container-image-reference") or "").split("docker://")[-1]
repo=ref.split("@")[0]
if ":" in repo.rsplit("/",1)[-1]:
    repo=repo.rsplit(":",1)[0]
print(ref or "-", repo or "-", b.get("container-image-reference-digest") or "-", b.get("version") or "unknown")
')
[[ -z "${ref}" || "${ref}" == "-" ]] && { fail "not running a container image"; exit 2; }
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { fail "rpm-ostree does not report the digest of the booted image"; exit 2; }
# the tag may already point at a newer build than the one booted, so check the booted digest itself
image="${repo}@${digest}"
echo "booted image : ${ref}"
echo "booted digest : ${digest}"
echo "booted version : ${version}"

meta="$("${SKOPEO}" inspect "docker://${image}" 2>/dev/null)" || { fail "cannot inspect ${image}"; exit 2; }
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
    if "${COSIGN}" verify --key "${OWN_KEY}" "${image}"; then
        ok "own signature valid"
    else
        fail "own signature INVALID for ${image}"
    fi
else
    fail "own public key missing at ${OWN_KEY}"
fi

matched_key=""
if [[ "${base_digest}" != "-" && "${base_digest}" != "unrecorded" ]]; then
    verified=0
    for k in "${UBLUE_KEYS[@]}"; do
        [[ -f "$k" ]] || continue
        if "${COSIGN}" verify --key "$k" "${base_image}@${base_digest}"; then
            ok "base image signed by ublue ($(basename "$k"))"
            matched_key="$(basename "$k")"
            verified=1
            break
        fi
    done
    (( verified )) || fail "base ${base_image}@${base_digest} is NOT signed by any known ublue key"
fi

if (( status == 0 )); then
    echo "chain OK"
    body="Booted image: ${ref}
Digest: ${digest:0:19}...
Version: ${version}
Own signature: valid (verified against ${OWN_KEY})

Base image: ${base_image}
Base digest: ${base_digest:0:19}...
Base signature: valid (verified against ublue's ${matched_key})

This confirms: the OS you're running was signed by your own key, and the
ublue image it was built on top of was itself signed by ublue - nothing in
the chain has been substituted or tampered with."
    notify info "OS Signature Chain: Verified" "${body}"
else
    notify crit "OS Signature Chain: FAILED" "${image} — see journalctl -u image-chain.service"
fi
exit "${status}"

#!/usr/bin/bash

set -eou pipefail

POLICY=/etc/containers/policy.json
SCOPE="ghcr.io/mccauliflower/aurora-zfs"
KEY=/etc/pki/containers/aurora-zfs.pub

if [[ ${EUID} -ne 0 ]]; then
    echo "run this with sudo: sudo ./install-policy.sh" >&2
    exit 64
fi

[[ -f "${KEY}" ]] || { echo "missing ${KEY} - run install-root.sh first" >&2; exit 1; }

install -d -o root -g root -m 0755 /etc/containers/registries.d
install -o root -g root -m 0644 registries.d-aurora-zfs.yaml \
    /etc/containers/registries.d/aurora-zfs.yaml
echo "sigstore attachment lookup enabled for ${SCOPE}"

backup="${POLICY}.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "${POLICY}" "${backup}"
echo "backed up to ${backup}"

tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

python3 - "${POLICY}" "${SCOPE}" "${KEY}" "${tmp}" <<'PY'
import json, sys
policy_path, scope, key, out = sys.argv[1:5]
p = json.load(open(policy_path))
docker = p.setdefault("transports", {}).setdefault("docker", {})
docker[scope] = [{
    "type": "sigstoreSigned",
    "keyPath": key,
    "signedIdentity": {"type": "matchRepository"},
}]
json.dump(p, open(out, "w"), indent=4)
PY

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${tmp}"
echo "new policy parses as valid json"

install -o root -g root -m 0644 "${tmp}" "${POLICY}"

echo
echo "scope installed:"
python3 -c "
import json
d=json.load(open('${POLICY}'))['transports']['docker']
for k in ('${SCOPE}',''):
    print('  %-40s %s' % (k or '<catch-all>', [r['type'] for r in d.get(k,[])]))
"
echo
echo "verifying existing image pulls still work..."
if skopeo inspect docker://ghcr.io/ublue-os/aurora:stable >/dev/null 2>&1; then
    echo "  ublue-os still pulls OK"
else
    echo "  WARNING: ublue-os pull broke - restore with: cp -a ${backup} ${POLICY}" >&2
    exit 1
fi

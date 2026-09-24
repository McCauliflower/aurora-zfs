#!/usr/bin/bash

set -eou pipefail

COSIGN_VERSION=v3.1.3
COSIGN_SHA256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71
COSIGN_URL="https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"

if [[ ${EUID} -ne 0 ]]; then
    echo "run this with sudo: sudo ./install-root.sh" >&2
    exit 64
fi

cd "$(dirname "$(readlink -f "$0")")"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

if [[ -f cosign-linux-amd64 ]]; then
    cp cosign-linux-amd64 "${tmp}/cosign"
else
    curl -fsSL -o "${tmp}/cosign" "${COSIGN_URL}"
fi

echo "${COSIGN_SHA256}  ${tmp}/cosign" | sha256sum -c -

install -o root -g root -m 0755 "${tmp}/cosign"        /usr/local/bin/cosign
install -o root -g root -m 0755 verify-image-chain.sh  /usr/local/bin/verify-image-chain.sh
install -o root -g root -m 0755 check-os-freshness.sh  /usr/local/bin/check-os-freshness.sh
install -d -o root -g root -m 0755 /etc/pki/containers

ls -la /usr/local/bin/cosign /usr/local/bin/verify-image-chain.sh /usr/local/bin/check-os-freshness.sh

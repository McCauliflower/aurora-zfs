#!/usr/bin/bash

set -uo pipefail

RPMOSTREE=/usr/bin/rpm-ostree
SKOPEO=/usr/bin/skopeo
PYTHON=/usr/bin/python3
SYSTEMCTL=/usr/bin/systemctl
SYSTEMD_CAT=/usr/bin/systemd-cat
NOTIFY_SEND=/usr/bin/notify-send

WARN_DAYS="${WARN_DAYS:-5}"
CRIT_DAYS="${CRIT_DAYS:-10}"
UPSTREAM=ghcr.io/ublue-os/aurora

status=0
notify() {
    local urgency="$1" title="$2" body="$3"
    echo "${title}: ${body}"
    "${SYSTEMD_CAT}" -t os-freshness -p "${urgency}" <<<"${title}: ${body}"
    [[ -x "${NOTIFY_SEND}" ]] && \
        "${NOTIFY_SEND}" -u "$([[ ${urgency} == crit ]] && echo critical || echo normal)" \
            "${title}" "${body}" 2>/dev/null
}

# prints "<days> <oldest upstream release newer than the base>", or "0 current"
upstream_lag() {
    local base="$1" latest base_version
    latest="$("${SKOPEO}" inspect --no-tags --format '{{.Digest}}' "docker://${UPSTREAM}:stable")" || return 1
    if [[ "${latest}" == "${base}" ]]; then
        echo "0 current"
        return
    fi
    base_version="$("${SKOPEO}" inspect --no-tags --format '{{index .Labels "org.opencontainers.image.version"}}' \
        "docker://${UPSTREAM}@${base}")" || return 1
    "${SKOPEO}" list-tags "docker://${UPSTREAM}" | "${PYTHON}" -c '
import json,sys,re,datetime
key=lambda m: (m.group(1), int(m.group(2)))
base=key(re.fullmatch(r"\d+\.(\d{8})\.(\d+)", sys.argv[1]))
newer=sorted((key(m), m.group(0)) for t in json.load(sys.stdin)["Tags"]
             if (m:=re.fullmatch(r"stable-(\d{8})\.(\d+)", t)) and key(m) > base)
(day,_),tag=newer[0]
released=datetime.datetime.strptime(day, "%Y%m%d").replace(tzinfo=datetime.timezone.utc)
print((datetime.datetime.now(datetime.timezone.utc)-released).days, tag)
' "${base_version}"
}

origin="" version="" base=""
if deployment="$("${RPMOSTREE}" status --json 2>&1)" \
    && deployment="$("${PYTHON}" -c '
import json,sys
b=[d for d in json.load(sys.stdin)["deployments"] if d.get("booted")][0]
ref=b.get("container-image-reference") or b.get("origin") or "unknown"
cfg=json.loads(b.get("base-commit-meta",{}).get("ostree.container.image-config") or "{}")
base=cfg.get("config",{}).get("Labels",{}).get("org.opencontainers.image.base.digest")
# stock aurora (e.g. after a rollback) is its own base
if not base and ref.endswith("docker://"+sys.argv[1]+":stable"):
    base=b.get("container-image-reference-digest")
print(ref, b.get("version") or "unknown", base or "unknown")
' "${UPSTREAM}" <<<"${deployment}" 2>&1)"; then
    read -r origin version base <<<"${deployment}"
    echo "booted : ${version}  (${origin})"
else
    notify crit "Freshness check is broken" \
        "Could not read the booted deployment from rpm-ostree status: $(tail -n 1 <<<"${deployment}"). Nothing about the booted image could be checked."
    status=2
fi

lag=""
[[ "${base}" =~ ^sha256:[0-9a-f]{64}$ ]] && lag="$(upstream_lag "${base}")"
if [[ -z "${origin}" ]]; then
    :   # rpm-ostree failure, already reported
elif [[ "${lag}" =~ ^(-?[0-9]+)\ (current|stable-[0-9]{8}\.[0-9]+)$ ]]; then
    age="${BASH_REMATCH[1]}" first="${BASH_REMATCH[2]}"
    if [[ "${first}" == current ]]; then
        echo "base   : current with ${UPSTREAM}:stable"
    else
        echo "base   : ${first} not booted, ${age} days"
    fi
    if (( age >= CRIT_DAYS )); then
        notify crit "OS is ${age} days behind upstream" \
            "Aurora ${first} is still not booted. Check for a nightly waiting for approval, the build, 'systemctl status uupd.service', or a pending reboot."
        status=2
    elif (( age >= WARN_DAYS )); then
        notify warning "OS is ${age} days behind upstream" "Aurora ${first} is not booted yet."
        status=1
    fi
else
    notify crit "Freshness check is broken" \
        "Could not tell how far the booted image (base ${base:-unknown}) is behind ${UPSTREAM}:stable. The monitor itself needs attention."
    status=2
fi

uupd_result="$("${SYSTEMCTL}" show uupd.service -p Result --value 2>/dev/null)"
echo "uupd   : ${uupd_result:-unknown}"
if [[ -n "${uupd_result}" && "${uupd_result}" != "success" ]]; then
    notify crit "Auto-update service failing" "uupd.service result=${uupd_result}"
    status=2
fi

if [[ "${origin}" == *ghcr.io* ]]; then
    ref="${origin##*docker://}"
    remote_age="$("${SKOPEO}" inspect "docker://${ref}" 2>/dev/null | "${PYTHON}" -c '
import json,sys,datetime
c=json.load(sys.stdin)["Created"]
c=datetime.datetime.fromisoformat(c.replace("Z","+00:00"))
print((datetime.datetime.now(datetime.timezone.utc)-c).days)
' 2>/dev/null)"
    if [[ "${remote_age}" =~ ^-?[0-9]+$ ]]; then
        echo "remote : ${remote_age} days old"
        if (( remote_age >= CRIT_DAYS )); then
            notify crit "Registry image is ${remote_age} days old" \
                "The nightly build is not publishing. This is the Bluefin LTS failure mode."
            status=2
        fi
    else
        notify crit "Freshness check is broken" \
            "Could not determine remote image age for ${ref}. The monitor itself needs attention."
        status=2
    fi
fi

(( status == 0 )) && echo "OK"
exit "${status}"

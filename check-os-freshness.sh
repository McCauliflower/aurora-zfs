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

status=0
notify() {
    local urgency="$1" title="$2" body="$3"
    echo "${title}: ${body}"
    "${SYSTEMD_CAT}" -t os-freshness -p "${urgency}" <<<"${title}: ${body}"
    [[ -x "${NOTIFY_SEND}" ]] && \
        "${NOTIFY_SEND}" -u "$([[ ${urgency} == crit ]] && echo critical || echo normal)" \
            "${title}" "${body}" 2>/dev/null
}

read -r origin version < <("${RPMOSTREE}" status --json | "${PYTHON}" -c '
import json,sys
b=[d for d in json.load(sys.stdin)["deployments"] if d.get("booted")][0]
print(b.get("container-image-reference") or b.get("origin") or "unknown", b.get("version") or "unknown")
')

build_date="$(grep -oE '[0-9]{8}' <<<"${version}" | head -1)"
if [[ -n "${build_date}" ]]; then
    age=$(( ( $(date +%s) - $(date -d "${build_date}" +%s) ) / 86400 ))
else
    age=-1
fi

echo "booted : ${version}  (${origin})"
echo "age    : ${age} days"

if (( age >= CRIT_DAYS )); then
    notify crit "OS image is ${age} days old" \
        "Updates appear to have stopped. Check the nightly build and 'systemctl status uupd.service'."
    status=2
elif (( age >= WARN_DAYS )); then
    notify warning "OS image is ${age} days old" "Expected a newer image by now."
    status=1
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

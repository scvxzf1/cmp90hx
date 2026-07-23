#!/usr/bin/env bash
set -Eeuo pipefail
readonly install_dir="/lib/modules/$(uname -r)/updates/cmp90hx-persistent"
readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly rm_query="${root_dir}/scripts/rm_issue_rate_query.py"
[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -s "${install_dir}/gpu_inventory" ]] || { echo 'No installed inventory for this kernel.' >&2; exit 1; }
[[ -f "${install_dir}/nvidia.ko.bootstrap" ]] || { echo 'Missing boot-stage module.' >&2; exit 1; }
count=0
while IFS= read -r bdf; do
    [[ -n "${bdf}" ]] || continue
    nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | tr '[:upper:]' '[:lower:]' | sed 's/^00000000:/0000:/' | grep -qx "${bdf}" || {
        echo "GPU missing from nvidia-smi: ${bdf}" >&2; exit 1; }
    count=$((count + 1))
done < "${install_dir}/gpu_inventory"
systemctl is-active --quiet cmp90hx-persistent.service || { echo 'Boot handoff service is not active.' >&2; exit 1; }
while IFS= read -r bdf; do
    [[ -n "${bdf}" ]] || continue
    row="$(nvidia-smi --query-gpu=pci.bus_id,uuid,driver_version,memory.total --format=csv,noheader,nounits | \
        awk -F, -v want="${bdf}" '{ x=tolower($1); sub(/^00000000:/, "0000:", x); if (x == want) print; }')"
    [[ -n "${row}" ]] || { echo "GPU absent from RM query: ${bdf}" >&2; exit 1; }
    IFS=',' read -r _ uuid driver memory <<< "${row}"
    uuid="$(xargs <<< "${uuid}")"
    driver="$(xargs <<< "${driver}")"
    memory="$(xargs <<< "${memory}")"
    python3 "${rm_query}" --bdf "${bdf}" --uuid "${uuid}" --driver "${driver}" \
        --memory-mib "${memory}" --expect full >/dev/null
done < "${install_dir}/gpu_inventory"
printf 'PASS_CMP90HX_PERSISTENT_COMPUTE_UNLOCK (%s GPU(s))\n' "${count}"

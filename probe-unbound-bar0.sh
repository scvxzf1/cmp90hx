#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly config="${script_dir}/config.env"
readonly run_dir="${script_dir}/probes/unbound-bar0-$(date -u +%Y%m%dT%H%M%SZ)"
[[ "$(id -u)" -eq 0 ]]
[[ -f "${config}" ]]
# shellcheck disable=SC1090
source "${config}"

mkdir -p "${run_dir}"
unloaded=0

wait_gpu_healthy() {
    local deadline=$((SECONDS + 90))
    while (( SECONDS < deadline )); do
        if nvidia-smi -L >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

restore_stock() {
    local rc="$?"
    trap - EXIT HUP INT TERM
    set +e
    if (( unloaded == 1 )); then
        modprobe nvidia
        modprobe nvidia_uvm
        modprobe nvidia_modeset
        modprobe nvidia_drm
        wait_gpu_healthy
        systemctl start nvidia-persistenced.service >/dev/null 2>&1 || true
        unloaded=0
    fi
    nvidia-smi --query-gpu=uuid,driver_version --format=csv,noheader \
        > "${run_dir}/identity-after.csv" 2>&1
    exit "${rc}"
}
trap restore_stock EXIT HUP INT TERM

[[ "$(nvidia-smi -L | wc -l)" -eq 1 ]]
[[ -z "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | xargs)" ]]
[[ "$(<"/sys/bus/pci/devices/${CMP90_BDF}/vendor")" == "0x10de" ]]
[[ "$(<"/sys/bus/pci/devices/${CMP90_BDF}/device")" == "0x220d" ]]
nvidia-smi --query-gpu=uuid,driver_version,vbios_version,memory.total \
    --format=csv,noheader > "${run_dir}/identity-before.csv"

systemctl stop nvidia-persistenced.service >/dev/null 2>&1 || true
unloaded=1
for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if [[ -d "/sys/module/${module}" ]]; then
        modprobe -r "${module}"
    fi
done
[[ ! -e "/sys/bus/pci/devices/${CMP90_BDF}/driver" ]]

python3 "${script_dir}/scripts/bar0_unbound_snapshot.py" \
    --bdf "${CMP90_BDF}" \
    --output "${run_dir}/bar0-snapshot.json" \
    | tee "${run_dir}/bar0-snapshot.stdout"

printf 'PASS_CMP90HX_UNBOUND_BAR0_SNAPSHOT\n%s\n' "${run_dir}"

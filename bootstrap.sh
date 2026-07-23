#!/usr/bin/env bash
set -Eeuo pipefail

readonly kernel="$(uname -r)"
readonly install_dir="/lib/modules/${kernel}/updates/cmp90hx-persistent"
readonly stock_module="${install_dir}/backup/nvidia.ko.stock"
readonly bootstrap_module="${install_dir}/nvidia.ko.bootstrap"
readonly inventory="${install_dir}/gpu_inventory"

log() { logger -t cmp90hx-persistent -- "$*"; echo "cmp90hx-persistent: $*"; }
[[ -s "${inventory}" && -f "${stock_module}" && -f "${bootstrap_module}" ]] || {
    log 'missing installation state'; exit 1;
}

# Start the bootstrap module explicitly.  Its V67 sequence completes during
# early GSP initialization; 75 seconds covers the measured 61-second worst
# case with margin.  Do not call nvidia-smi before the FLR: its probe against
# the intentionally incomplete bootstrap device floods the kernel journal.
modprobe ecc || true
modprobe nvidia
sleep 75
log 'bootstrap delay complete; handing off through FLR'

systemctl stop nvidia-cdi-refresh.path nvidia-cdi-refresh.service \
    nvidia-persistenced.service >/dev/null 2>&1 || true
for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    modprobe -r "${module}" >/dev/null 2>&1 || true
done
for bdf in $(cat "${inventory}"); do
    reset="/sys/bus/pci/devices/${bdf}/reset"
    [[ -w "${reset}" ]] || { log "FLR unavailable for ${bdf}"; exit 1; }
    printf 1 > "${reset}"
done
sleep 2

# The initramfs retains nvidia.ko.bootstrap for the next boot.  Runtime uses
# the backed-up vendor module after the FLR, matching the proven manual flow.
install -m 0644 "${stock_module}" "${install_dir}/nvidia.ko"
depmod -a "${kernel}"
modprobe nvidia
modprobe nvidia_uvm
modprobe nvidia_modeset
modprobe nvidia_drm

deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
    if nvidia-smi -L >/dev/null 2>&1; then
        systemctl start --no-block nvidia-persistenced.service \
            nvidia-cdi-refresh.path >/dev/null 2>&1 || true
        log 'vendor driver is online after FLR handoff'
        exit 0
    fi
    sleep 2
done
log 'vendor driver did not recover after FLR handoff'
exit 1

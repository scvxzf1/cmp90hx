#!/usr/bin/env bash
set -Eeuo pipefail

readonly mode="${1:-}"
[[ "${mode}" == "run" || "${mode}" == "preflight-only" || \
    "${mode}" == "probe-after-candidate" ]]
readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly config="${script_dir}/config.env"
[[ -f "${config}" ]]
# shellcheck disable=SC1090
source "${config}"

: "${CMP90_BDF:?}"
: "${CMP90_UUID:?}"
: "${CMP90_KERNEL:?}"
: "${CMP90_DRIVER:?}"
: "${CMP90_MEMORY_MIB:?}"
: "${CMP90_VBIOS:?}"
: "${CMP90_STOCK_MODULE:?}"
: "${CMP90_STOCK_SHA256:?}"
: "${CMP90_CANDIDATE:?}"
: "${CMP90_CANDIDATE_SHA256:?}"

readonly device_dir="/sys/bus/pci/devices/${CMP90_BDF}"
readonly rm_query="${script_dir}/scripts/rm_issue_rate_query.py"
readonly apply_tool="${script_dir}/scripts/bar0_apply_compute_override.py"
readonly run_id="compute-unlock-$(date -u +%Y%m%dT%H%M%SZ)"
readonly run_dir="${script_dir}/runs/${run_id}"
# `journalctl --since @epoch` is portable on the target's systemd version and
# preserves the candidate-module evidence needed by this experimental run.
readonly start_time="@$(date -u +%s)"
readonly recovery_unit="cmp90hx-share-poweroff-$(date -u +%H%M%S)"
readonly disarm_marker="/run/${run_id}.disarmed"
readonly fatal_re='NVRM: Xid|GPU has fallen off the bus|AER:.*(Uncorrected|Fatal)|PCIe Bus Error.*(Uncorrected|Fatal)|hard LOCKUP|soft lockup|kernel BUG|Oops:|Kernel panic|MMU Fault'

recovery_required=0
timer_armed=0
override_applied=0
mkdir -p "${run_dir}"

log() {
    printf '[%s] %s\n' "$(date -u --iso-8601=seconds)" "$*" |
        tee -a "${run_dir}/transaction.log"
}

module_loaded() {
    [[ -d "/sys/module/$1" ]]
}

capture_identity() {
    local output="$1"
    nvidia-smi \
        --query-gpu=index,name,pci.device_id,pci.sub_device_id,uuid,driver_version,memory.total,memory.used,power.draw,power.limit,temperature.gpu,pstate \
        --format=csv,noheader > "${output}"
}

run_rate_query() {
    local expectation="$1"
    local output="$2"
    python3 "${rm_query}" \
        --bdf "${CMP90_BDF}" \
        --uuid "${CMP90_UUID}" \
        --driver "${CMP90_DRIVER}" \
        --memory-mib "${CMP90_MEMORY_MIB}" \
        --expect "${expectation}" \
        --output "${output}" >/dev/null
}

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

unload_nvidia() {
    local attempt module all_unloaded
    for attempt in {1..30}; do
        systemctl stop nvidia-persistenced.service >/dev/null 2>&1 || true
        udevadm settle >/dev/null 2>&1 || true
        for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            if module_loaded "${module}"; then
                modprobe -r "${module}" >/dev/null 2>&1 || true
            fi
        done
        all_unloaded=1
        for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            if module_loaded "${module}"; then
                all_unloaded=0
            fi
        done
        if (( all_unloaded == 1 )); then
            return 0
        fi
        sleep 1
    done
    lsmod | grep -E '^(nvidia|ecc)' | tee -a "${run_dir}/transaction.log" || true
    return 1
}

reset_target() {
    [[ -w "${device_dir}/reset" ]]
    printf '1' > "${device_dir}/reset"
    sleep 2
}

arm_recovery() {
    sync
    systemd-run --quiet \
        --unit="${recovery_unit}" \
        --timer-property=AccuracySec=1s \
        --on-active=600s \
        /bin/bash -c \
        "if [[ ! -e '${disarm_marker}' ]]; then sync; sleep 2; printf o > /proc/sysrq-trigger; fi"
    timer_armed=1
    log "armed 600-second emergency power-off timer"
}

disarm_recovery() {
    if (( timer_armed == 1 )); then
        touch "${disarm_marker}"
        systemctl stop \
            "${recovery_unit}.timer" \
            "${recovery_unit}.service" >/dev/null 2>&1 || true
        timer_armed=0
        log "recovery timer disarmed"
    fi
}

recover_stock_before_override() {
    local recovery_ok=1
    set +e
    log "recovery: unloading candidate, FLR, and restoring installed stock modules"
    systemctl stop nvidia-persistenced.service
    unload_nvidia || recovery_ok=0
    if (( recovery_ok == 1 )); then
        reset_target || recovery_ok=0
    fi
    if (( recovery_ok == 1 )); then
        modprobe nvidia || recovery_ok=0
        modprobe nvidia_uvm || recovery_ok=0
        modprobe nvidia_modeset || recovery_ok=0
        modprobe nvidia_drm || recovery_ok=0
    fi
    if (( recovery_ok == 1 )); then
        wait_gpu_healthy || recovery_ok=0
    fi
    if (( recovery_ok == 1 )); then
        systemctl start nvidia-persistenced.service || recovery_ok=0
        [[ "$(sha256sum "$(modinfo -F filename nvidia)" | awk '{print $1}')" == \
            "${CMP90_STOCK_SHA256}" ]] || recovery_ok=0
        run_rate_query locked "${run_dir}/rm-rates-recovered-stock.json" ||
            recovery_ok=0
    fi
    journalctl -b -k --since "${start_time}" --no-pager \
        > "${run_dir}/kernel-through-recovery.txt"
    if (( recovery_ok == 1 )); then
        recovery_required=0
        printf 'RECOVERED_STOCK_90HX\n' > "${run_dir}/RECOVERY"
        disarm_recovery
        log "recovery: installed stock driver and locked rates verified"
        set -e
        return 0
    fi
    printf 'RECOVERY_PENDING_AUTOMATIC_POWEROFF\n' > "${run_dir}/RECOVERY"
    log "recovery incomplete; emergency power-off timer remains armed"
    sync
    set -e
    return 1
}

finish_hashes() {
    find "${run_dir}" -maxdepth 1 -type f ! -name SHA256SUMS -print0 |
        sort -z | xargs -0 sha256sum > "${run_dir}/SHA256SUMS" || true
}

on_exit() {
    local rc="$?"
    trap - EXIT HUP INT TERM
    if (( recovery_required == 1 && override_applied == 0 )); then
        recover_stock_before_override || true
    elif (( recovery_required == 1 )); then
        log "post-override failure: evidence preserved; emergency power-off remains armed"
    fi
    finish_hashes
    sync
    exit "${rc}"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

log "preflight begins"
[[ "$(id -u)" -eq 0 ]]
for command in fuser insmod journalctl jq modinfo modprobe nvidia-smi \
    python3 setpci sha256sum strings systemctl systemd-run timeout udevadm; do
    command -v "${command}" >/dev/null
done
[[ "$(uname -m)" == "x86_64" ]]
[[ "$(uname -r)" == "${CMP90_KERNEL}" ]]
[[ "${CMP90_DRIVER}" == "580.159.03" ]]
[[ "${CMP90_MEMORY_MIB}" == "10240" ]]
[[ -d "${device_dir}" ]]
[[ "$(<"${device_dir}/vendor")" == "0x10de" ]]
[[ "$(<"${device_dir}/device")" == "0x220d" ]]
[[ "$(<"${device_dir}/subsystem_vendor")" == "0x10de" ]]
[[ "$(<"${device_dir}/subsystem_device")" == "0x1555" ]]
[[ "$(nvidia-smi -L | wc -l)" -eq 1 ]]
[[ "$(nvidia-smi --query-gpu=vbios_version --format=csv,noheader | xargs)" == \
    "${CMP90_VBIOS}" ]]
[[ "$(modinfo -F filename nvidia)" == "${CMP90_STOCK_MODULE}" ]]
[[ "$(sha256sum "${CMP90_STOCK_MODULE}" | awk '{print $1}')" == \
    "${CMP90_STOCK_SHA256}" ]]
[[ "$(modinfo -F version nvidia)" == "${CMP90_DRIVER}" ]]
[[ -f "${CMP90_CANDIDATE}" ]]
[[ "$(sha256sum "${CMP90_CANDIDATE}" | awk '{print $1}')" == \
    "${CMP90_CANDIDATE_SHA256}" ]]
[[ "$(modinfo -F version "${CMP90_CANDIDATE}")" == "${CMP90_DRIVER}" ]]
[[ "$(modinfo -F vermagic "${CMP90_CANDIDATE}" | awk '{print $1}')" == \
    "${CMP90_KERNEL}" ]]
strings "${CMP90_CANDIDATE}" > "${run_dir}/candidate.strings"
grep -q 'CMP90_PROD_STACK_SHIFT_PLM_V67: native GA102 status=' \
    "${run_dir}/candidate.strings"
[[ -f "${rm_query}" && -f "${apply_tool}" ]]
[[ -z "$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | xargs)" ]]
capture_identity "${run_dir}/identity-before.csv"
run_rate_query locked "${run_dir}/rm-rates-before.json"
sha256sum "${CMP90_STOCK_MODULE}" "${CMP90_CANDIDATE}" \
    "${rm_query}" "${apply_tool}" > "${run_dir}/input-sha256.txt"
log "preflight passed"

if [[ "${mode}" == "preflight-only" ]]; then
    printf 'PASS_CMP90HX_UNLOCK_PREFLIGHT_ONLY\n' > "${run_dir}/RESULT"
    finish_hashes
    trap - EXIT HUP INT TERM
    printf 'PASS_CMP90HX_UNLOCK_PREFLIGHT_ONLY\n%s\n' "${run_dir}"
    exit 0
fi

systemctl stop nvidia-persistenced.service
sleep 2
if fuser -s /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm 2>/dev/null; then
    log "GPU clients remain after persistence daemon stop"
    exit 20
fi

arm_recovery
recovery_required=1
unload_nvidia
reset_target

log "loading temporary V67 candidate"
modprobe ecc
insmod "${CMP90_CANDIDATE}" \
    NVreg_OpenRmEnableUnsupportedGpus=1 \
    NVreg_EnableGpuFirmware=18 \
    NVreg_EnableGpuFirmwareLogs=2

set +e
timeout 20s nvidia-smi -L \
    > "${run_dir}/trigger.stdout" \
    2> "${run_dir}/trigger.stderr"
trigger_rc="$?"
set -e
printf '%s\n' "${trigger_rc}" > "${run_dir}/trigger.exit-code"
sleep 2

journalctl -b -k --since "${start_time}" --no-pager \
    > "${run_dir}/kernel-v67.txt"
[[ "$(grep -c 'CMP90_PROD_STACK_SHIFT_PLM_V67: native GA102 status=' \
    "${run_dir}/kernel-v67.txt")" -eq 1 ]]
grep -Eq 'FEAT_PLM_before=0x(ffffff8f|ffffffff) FEAT_PLM_after=0xffffffff' \
    "${run_dir}/kernel-v67.txt"
grep -q 'memdesc=64000 wpr_meta=64000' "${run_dir}/kernel-v67.txt"
! grep -Eq "${fatal_re}" "${run_dir}/kernel-v67.txt"
log "FEAT_OVR_PLM is open"

unload_nvidia
[[ ! -e "${device_dir}/driver" ]]
if ! (( 0x$(setpci -s "${CMP90_BDF}" COMMAND) & 0x2 )); then
    log "PCI Memory Space Enable is clear"
    exit 32
fi

if [[ "${mode}" == "probe-after-candidate" ]]; then
    python3 "${script_dir}/scripts/bar0_unbound_snapshot.py" \
        --bdf "${CMP90_BDF}" \
        --output "${run_dir}/bar0-after-candidate.json" \
        > "${run_dir}/bar0-after-candidate.stdout"
    jq -e '.hardware_writes == 0' \
        "${run_dir}/bar0-after-candidate.json" >/dev/null
    printf 'PASS_CMP90HX_CANDIDATE_BAR0_PROBE\n' > "${run_dir}/RESULT"
    log "post-candidate BAR0 snapshot captured; no selector writes"
    exit 0
fi

python3 "${apply_tool}" \
    --bdf "${CMP90_BDF}" \
    --output "${run_dir}/bar0-compute-override.json" \
    > "${run_dir}/bar0-compute-override.stdout"
jq -e '.result == "PASS_COMPUTE_OVERRIDE_APPLIED" and .hardware_writes == 2' \
    "${run_dir}/bar0-compute-override.json" >/dev/null
override_applied=1
log "full-speed selectors accepted"

reset_target
modprobe nvidia
modprobe nvidia_uvm
modprobe nvidia_modeset
modprobe nvidia_drm
wait_gpu_healthy
systemctl start nvidia-persistenced.service

capture_identity "${run_dir}/identity-unlocked-stock.csv"
[[ "$(sha256sum "$(modinfo -F filename nvidia)" | awk '{print $1}')" == \
    "${CMP90_STOCK_SHA256}" ]]
run_rate_query full "${run_dir}/rm-rates-unlocked.json"
journalctl -b -k --since "${start_time}" --no-pager \
    > "${run_dir}/kernel-through-unlocked-stock.txt"
! grep -Eq "${fatal_re}" "${run_dir}/kernel-through-unlocked-stock.txt"

printf 'PASS_CMP90HX_COMPUTE_UNLOCK_FULL_SPEED\n' > "${run_dir}/RESULT"
printf 'UNLOCKED_STOCK_580_159_03\n' > "${run_dir}/STATE"
recovery_required=0
disarm_recovery
finish_hashes
trap - EXIT HUP INT TERM
printf 'PASS_CMP90HX_COMPUTE_UNLOCK_FULL_SPEED\n%s\n' "${run_dir}"

#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly kernel_release="$(uname -r)"
readonly candidate="${script_dir}/artifacts/nvidia-v67-${kernel_release}.ko"
readonly config="${script_dir}/config.env"

[[ "$(id -u)" -eq 0 ]]
for command in nvidia-smi modinfo sha256sum lspci; do
    command -v "${command}" >/dev/null
done
[[ "$(uname -m)" == "x86_64" ]]
[[ -f "${candidate}" ]]

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null |
    grep -qi 'SecureBoot enabled'; then
    printf 'Secure Boot is enabled; refusing unsigned temporary module.\n' >&2
    exit 11
fi

matches=()
for device_dir in /sys/bus/pci/devices/*; do
    [[ -f "${device_dir}/vendor" ]] || continue
    [[ "$(<"${device_dir}/vendor")" == "0x10de" ]] || continue
    [[ "$(<"${device_dir}/device")" == "0x220d" ]] || continue
    [[ "$(<"${device_dir}/subsystem_vendor")" == "0x10de" ]] || continue
    [[ "$(<"${device_dir}/subsystem_device")" == "0x1555" ]] || continue
    matches+=("${device_dir}")
done
[[ "${#matches[@]}" -eq 1 ]]
[[ "$(nvidia-smi -L | wc -l)" -eq 1 ]]

readonly device_dir="${matches[0]}"
readonly bdf="$(basename "${device_dir}")"
readonly smi_row="$(nvidia-smi \
    --query-gpu=uuid,driver_version,memory.total,vbios_version \
    --format=csv,noheader,nounits)"
IFS=',' read -r uuid driver_version memory_mib vbios_version <<< "${smi_row}"
uuid="$(xargs <<< "${uuid}")"
driver_version="$(xargs <<< "${driver_version}")"
memory_mib="$(xargs <<< "${memory_mib}")"
vbios_version="$(xargs <<< "${vbios_version}")"

[[ "${driver_version}" == "580.159.03" ]]
[[ "${memory_mib}" == "10240" ]]
[[ "${vbios_version}" == "94.02.74.00.01" ]]
[[ "$(modinfo -F version nvidia)" == "580.159.03" ]]
[[ "$(modinfo -F version "${candidate}")" == "580.159.03" ]]
[[ "$(modinfo -F vermagic "${candidate}" | awk '{print $1}')" == \
    "${kernel_release}" ]]

readonly stock_module="$(modinfo -F filename nvidia)"
readonly stock_sha256="$(sha256sum "${stock_module}" | awk '{print $1}')"
readonly candidate_sha256="$(sha256sum "${candidate}" | awk '{print $1}')"

umask 077
{
    printf 'CMP90_BDF=%q\n' "${bdf}"
    printf 'CMP90_UUID=%q\n' "${uuid}"
    printf 'CMP90_KERNEL=%q\n' "${kernel_release}"
    printf 'CMP90_DRIVER=%q\n' "${driver_version}"
    printf 'CMP90_MEMORY_MIB=%q\n' "${memory_mib}"
    printf 'CMP90_VBIOS=%q\n' "${vbios_version}"
    printf 'CMP90_STOCK_MODULE=%q\n' "${stock_module}"
    printf 'CMP90_STOCK_SHA256=%q\n' "${stock_sha256}"
    printf 'CMP90_CANDIDATE=%q\n' "${candidate}"
    printf 'CMP90_CANDIDATE_SHA256=%q\n' "${candidate_sha256}"
} > "${config}"

printf 'PASS_CMP90HX_CONFIGURED\n%s\n' "${config}"

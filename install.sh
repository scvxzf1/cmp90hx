#!/usr/bin/env bash
# Build and install the prepatched CMP90HX direct-compute bootstrap without
# replacing the distribution's runtime nvidia.ko. This main-branch installer
# never downloads source or applies a patch.
set -Eeuo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly driver_version="580.159.03"
readonly kernel="$(uname -r)"
readonly bundled_source="${root_dir}/work/cmp90hx-persistent-build"
readonly build_dir="${root_dir}/work/cmp90hx-build-${kernel}"
readonly install_dir="/lib/modules/${kernel}/updates/cmp90hx-persistent"
readonly helper_dir="/usr/local/lib/cmp90hx-persistent"
readonly unit_name="cmp90hx-persistent.service"
readonly unit_path="/etc/systemd/system/${unit_name}"
declare -a cards=()

die() { printf 'FAIL_CMP90HX_INSTALL: %s\n' "$*" >&2; exit 1; }

discover_cards() {
    mapfile -t cards < <(
        for dev in /sys/bus/pci/devices/*; do
            [[ -r "${dev}/vendor" && -r "${dev}/device" &&
               -r "${dev}/subsystem_vendor" && -r "${dev}/subsystem_device" ]] || continue
            [[ "$(<"${dev}/vendor")" == 0x10de &&
               "$(<"${dev}/device")" == 0x220d &&
               "$(<"${dev}/subsystem_vendor")" == 0x10de &&
               "$(<"${dev}/subsystem_device")" == 0x1555 ]] || continue
            bdf="$(basename "${dev}")"
            grep -qw bus "${dev}/reset_method" 2>/dev/null ||
                die "${bdf} does not expose the required PCIe bus reset method"
            printf '%s\n' "${bdf}"
        done | sort -V
    )
}

select_source() {
    if [[ -n "${CMP90_SOURCE_DIR:-}" ]]; then
        printf '%s\n' "${CMP90_SOURCE_DIR}"
    else
        printf '%s\n' "${bundled_source}"
    fi
}

prepare_source() {
    local source_dir="$1"
    [[ -d "${source_dir}" ]] || die "missing bundled prepatched source: ${source_dir}"
    [[ -f "${source_dir}/version.mk" ]] || die "not an NVIDIA kernel-module source tree: ${source_dir}"
    grep -qx "NVIDIA_VERSION = ${driver_version}" "${source_dir}/version.mk" ||
        die "source version is not ${driver_version}: ${source_dir}"
    grep -Fq 'CMP90HX: compute selectors enabled' "${source_dir}/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c" ||
        die 'bundled source does not contain the direct compute patch'
}

[[ "${EUID}" -eq 0 ]] || die 'run as root'
for command in make gcc ld objcopy sha256sum strings install systemctl modinfo \
               modprobe insmod depmod nproc python3 timeout; do
    command -v "${command}" >/dev/null || die "missing command: ${command}"
done
[[ -d "/lib/modules/${kernel}/build" ]] || die "missing kernel headers for ${kernel}"

runtime_module="$(modinfo -n nvidia)"
[[ "${runtime_module}" == "/lib/modules/${kernel}/"* && -f "${runtime_module}" ]] ||
    die "unexpected nvidia.ko path: ${runtime_module}"
[[ "$(modinfo -F version "${runtime_module}")" == "${driver_version}" ]] ||
    die "requires NVIDIA Open ${driver_version}"
[[ "$(modinfo -F license "${runtime_module}")" == *MIT/GPL* ]] ||
    die 'requires the NVIDIA Open kernel module, not the proprietary module'
if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    die 'Secure Boot is enabled; refusing the unsigned bootstrap module'
fi

discover_cards
(( ${#cards[@]} > 0 )) || die 'no CMP90HX 10de:220d/10de:1555 cards found'

source_seed="$(select_source)"
prepare_source "${source_seed}"

install -d -m 0755 "${install_dir}/backup"
if [[ ! -s "${install_dir}/backup/nvidia.ko.stock" ]]; then
    install -m 0644 "${runtime_module}" "${install_dir}/backup/nvidia.ko.stock"
    sha256sum "${runtime_module}" "${install_dir}/backup/nvidia.ko.stock" \
        > "${install_dir}/backup/SHA256SUMS"
fi
printf '%s\n' "${runtime_module}" > "${install_dir}/runtime_module_path"
printf '%s\n' "${driver_version}" > "${install_dir}/driver_version"
printf '%s\n' "${cards[@]}" > "${install_dir}/gpu_inventory"

install -d -m 0755 "${root_dir}/work"
rm -rf "${build_dir}"
cp -a "${source_seed}" "${build_dir}"
make -C "${build_dir}" -j"$(nproc)" modules KERNEL_UNAME="${kernel}"

candidate="${build_dir}/kernel-open/nvidia.ko"
[[ -f "${candidate}" ]] || die 'candidate nvidia.ko was not built'
[[ "$(modinfo -F version "${candidate}")" == "${driver_version}" ]] ||
    die 'candidate driver version mismatch'
[[ "$(modinfo -F vermagic "${candidate}" | awk '{print $1}')" == "${kernel}" ]] ||
    die 'candidate kernel vermagic mismatch'
strings "${candidate}" | grep -F 'CMP90HX: compute selectors enabled' >/dev/null ||
    die 'candidate does not contain the CMP90HX direct compute bootstrap'

install -m 0644 "${candidate}" "${install_dir}/nvidia.ko.bootstrap"
sha256sum "${install_dir}/nvidia.ko.bootstrap" \
    "${install_dir}/backup/nvidia.ko.stock" > "${install_dir}/SHA256SUMS"

install -d -m 0755 "${helper_dir}"
install -m 0755 "${root_dir}/cmp90hx-v67-one-test.sh" "${helper_dir}/cmp90hx-v67-one-test.sh"
install -m 0755 "${root_dir}/cmp90hx-batch-bus-test.sh" "${helper_dir}/cmp90hx-batch-bus-test.sh"
install -m 0755 "${root_dir}/cmp90hx-defer-hive-services.sh" "${helper_dir}/cmp90hx-defer-hive-services.sh"
install -m 0755 "${root_dir}/cmp90hx-one.sh" "${helper_dir}/cmp90hx-one.sh"
install -m 0755 "${root_dir}/cmp90hx-batch.sh" "${helper_dir}/cmp90hx-batch.sh"
install -m 0755 "${root_dir}/defer-services.sh" "${helper_dir}/defer-services.sh"
install -m 0644 "${root_dir}/cmp90hx-persistent.service" "${unit_path}"

systemctl daemon-reload
systemctl enable "${unit_name}"

printf '%s\n' 'PASS_CMP90HX_PERSISTENT_INSTALLED'
printf 'Stock backup: %s\nBootstrap candidate: %s\nCards: %s\n' \
    "${install_dir}/backup/nvidia.ko.stock" \
    "${install_dir}/nvidia.ko.bootstrap" "${cards[*]}"
printf '%s\n' 'The stock nvidia.ko was not replaced. Reboot to run the persistent bootstrap.'

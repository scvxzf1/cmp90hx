#!/usr/bin/env bash
set -Eeuo pipefail

readonly root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly version="580.159.03"
readonly kernel="$(uname -r)"
readonly source_seed="${root_dir}/work/o"
readonly build_dir="${root_dir}/work/cmp90hx-persistent-build"
readonly patch_file="${root_dir}/patches/0001-58015903-cmp90hx-persistent-compute.patch"
readonly install_dir="/lib/modules/${kernel}/updates/cmp90hx-persistent"

[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -d "/lib/modules/${kernel}/build" ]] || { echo "Missing headers for ${kernel}." >&2; exit 1; }
[[ -d "${source_seed}/.git" && -f "${patch_file}" ]] || { echo 'Missing bundled 580.159.03 source or patch.' >&2; exit 1; }
[[ "$(modinfo -F version nvidia)" == "${version}" ]] || { echo "Requires nvidia-open ${version}." >&2; exit 1; }

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
    echo 'Secure Boot is enabled; refusing unsigned module installation.' >&2
    exit 1
fi

cards=()
for dev in /sys/bus/pci/devices/*; do
    [[ -f "${dev}/vendor" ]] || continue
    if [[ "$(<"${dev}/vendor")" == 0x10de && "$(<"${dev}/device")" == 0x220d &&
          "$(<"${dev}/subsystem_vendor")" == 0x10de && "$(<"${dev}/subsystem_device")" == 0x1555 ]]; then
        cards+=("$(basename "${dev}")")
    fi
done
(( ${#cards[@]} > 0 )) || { echo 'No supported CMP90HX (220d/1555) cards found.' >&2; exit 1; }

stock="$(modinfo -F filename nvidia)"
mkdir -p "${install_dir}/backup"
if [[ ! -f "${install_dir}/backup/nvidia.ko.stock" ]]; then
    install -m 0644 "${stock}" "${install_dir}/backup/nvidia.ko.stock"
    sha256sum "${stock}" "${install_dir}/backup/nvidia.ko.stock" > "${install_dir}/backup/SHA256SUMS"
fi
printf '%s\n' "${version}" > "${install_dir}/driver_version"
printf '%s\n' "${cards[@]}" > "${install_dir}/gpu_inventory"

rm -rf "${build_dir}"
cp -a "${source_seed}" "${build_dir}"
git -C "${build_dir}" apply --check "${patch_file}"
git -C "${build_dir}" apply "${patch_file}"
make -C "${build_dir}" -j"$(nproc)" modules KERNEL_UNAME="${kernel}"

for module in nvidia nvidia-modeset nvidia-uvm nvidia-drm nvidia-peermem; do
    src="${build_dir}/kernel-open/${module}.ko"
    [[ -f "${src}" ]] && install -m 0644 "${src}" "${install_dir}/${module}.ko"
done
[[ -f "${install_dir}/nvidia.ko" ]] || { echo 'Patched nvidia.ko was not built.' >&2; exit 1; }
install -m 0644 "${install_dir}/nvidia.ko" "${install_dir}/nvidia.ko.bootstrap"
modinfo "${install_dir}/nvidia.ko" | grep -q "^version:.*${version}$"
sha256sum "${install_dir}"/*.ko > "${install_dir}/SHA256SUMS"
install -d -m 0755 /etc/modprobe.d
printf '%s\n' \
    'options nvidia NVreg_OpenRmEnableUnsupportedGpus=1 NVreg_EnableGpuFirmware=18 NVreg_EnableGpuFirmwareLogs=2' \
    > /etc/modprobe.d/cmp90hx-persistent.conf
install -d -m 0755 /usr/local/lib/cmp90hx-persistent
install -m 0755 "${root_dir}/bootstrap.sh" /usr/local/lib/cmp90hx-persistent/bootstrap.sh
install -m 0644 "${root_dir}/cmp90hx-persistent.service" /etc/systemd/system/cmp90hx-persistent.service
systemctl daemon-reload
systemctl enable cmp90hx-persistent.service
depmod -a "${kernel}"

if command -v update-initramfs >/dev/null; then update-initramfs -u -k "${kernel}"; fi
if command -v dracut >/dev/null && ! command -v update-initramfs >/dev/null; then dracut --force --kver "${kernel}"; fi

resolved="$(modinfo -n nvidia)"
[[ "${resolved}" == "${install_dir}/nvidia.ko" ]] || { echo "Unexpected module resolution: ${resolved}" >&2; exit 1; }
printf 'PASS_CMP90HX_PERSISTENT_MODULE_INSTALLED\nBackup: %s\nCards: %s\nReboot required.\n' \
    "${install_dir}/backup/nvidia.ko.stock" "${cards[*]}"

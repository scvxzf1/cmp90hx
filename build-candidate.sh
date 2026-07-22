#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly driver_version="580.159.03"
readonly source_commit="4dbb564094c7a73fe222b9b010d7782638643c65"
readonly kernel_release="${KERNEL_RELEASE:-$(uname -r)}"
readonly work_root="${script_dir}/work"
readonly source_dir="${work_root}/open-gpu-kernel-modules-${driver_version}"
readonly artifact_dir="${script_dir}/artifacts"
readonly candidate="${artifact_dir}/nvidia-v67-${kernel_release}.ko"
readonly patch_file="${script_dir}/patches/0001-58015903-cmp90hx-220d-1555-v67-open-plm.patch"

for command in git make gcc sha256sum strings; do
    command -v "${command}" >/dev/null
done
[[ -d "/lib/modules/${kernel_release}/build" ]]
[[ -f "${patch_file}" ]]

if [[ -e "${source_dir}" ]]; then
    printf 'Refusing to reuse existing source directory: %s\n' "${source_dir}" >&2
    printf 'Move it aside and run this script again.\n' >&2
    exit 10
fi

mkdir -p "${work_root}" "${artifact_dir}"
git clone --filter=blob:none --branch "${driver_version}" --depth 1 \
    https://github.com/NVIDIA/open-gpu-kernel-modules.git "${source_dir}"
[[ "$(git -C "${source_dir}" rev-parse HEAD)" == "${source_commit}" ]]
git -C "${source_dir}" apply --check "${patch_file}"
git -C "${source_dir}" apply "${patch_file}"

make -C "${source_dir}" modules -j"$(nproc)" KERNEL_UNAME="${kernel_release}"
install -m 0644 "${source_dir}/kernel-open/nvidia.ko" "${candidate}"

[[ "$(modinfo -F version "${candidate}")" == "${driver_version}" ]]
[[ "$(modinfo -F vermagic "${candidate}" | awk '{print $1}')" == \
    "${kernel_release}" ]]
strings "${candidate}" | grep -q \
    'CMP90_PROD_STACK_SHIFT_PLM_V67: native GA102 status='

sha256sum "${candidate}" > "${candidate}.sha256"
printf 'PASS_CMP90HX_V67_BUILD\n%s\n' "${candidate}"


#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == '--yes' || "${1:-}" == '-y' ]] || { echo 'Run: sudo ./remove.sh --yes' >&2; exit 1; }
[[ "${EUID}" -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
systemctl disable --now cmp90hx-persistent.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/cmp90hx-persistent.service
rm -rf /usr/local/lib/cmp90hx-persistent
systemctl daemon-reload
rm -f /etc/modprobe.d/cmp90hx-persistent.conf
for dir in /lib/modules/*/updates/cmp90hx-persistent; do
    [[ -d "${dir}" ]] || continue
    kernel="$(basename "$(dirname "$(dirname "${dir}")")")"
    rm -rf "${dir}"
    depmod -a "${kernel}"
    if command -v update-initramfs >/dev/null; then update-initramfs -u -k "${kernel}"; fi
    if command -v dracut >/dev/null && ! command -v update-initramfs >/dev/null; then dracut --force --kver "${kernel}"; fi
done
echo 'Patched modules removed. Reboot to return to the stock driver.'

#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly config="${script_dir}/config.env"
readonly expectation="${2:-${1:-full}}"
[[ "${1:-}" != "--expect" || -n "${2:-}" ]]
[[ "${expectation}" == "full" || "${expectation}" == "locked" ]]
[[ "$(id -u)" -eq 0 ]]
[[ -f "${config}" ]]
# shellcheck disable=SC1090
source "${config}"

python3 "${script_dir}/scripts/rm_issue_rate_query.py" \
    --bdf "${CMP90_BDF}" \
    --uuid "${CMP90_UUID}" \
    --driver "${CMP90_DRIVER}" \
    --memory-mib "${CMP90_MEMORY_MIB}" \
    --expect "${expectation}"

if [[ "${expectation}" == "full" ]]; then
    printf 'PASS_CMP90HX_FULL_SPEED\n'
else
    printf 'PASS_CMP90HX_LOCKED_STOCK\n'
fi


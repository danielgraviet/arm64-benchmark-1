#!/usr/bin/env bash
# Create-ready 2000 with pre/post clean gate.
# Prefer: cd nvidia && ./o 2k  (starts tmux)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIDIA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${NVIDIA_DIR}/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/profile.sh"
_zen5_apply_profile

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1
export TARGET="${TARGET}"

bash "${SCRIPT_DIR}/clean_cell.sh"
TARGET="${TARGET}" bash "${ROOT}/scripts/host/run_create_ready.sh" 2000
status=$?
bash "${SCRIPT_DIR}/clean_cell.sh" || true
exit "${status}"

#!/usr/bin/env bash
# Dense agent ladder 44→2000 (n=45) with pre/post clean gate.
# Prefer: cd nvidia && ./o full-ladder  (starts tmux)
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

bash "${SCRIPT_DIR}/clean_cell.sh"
if [[ "${ZEN5_PROFILE}" == "phoenix-e6" ]]; then
  bash "${ROOT}/scripts/host/run_dense2k_9j45.sh"
else
  bash "${ROOT}/scripts/host/run_dense2k.sh"
fi
status=$?
bash "${SCRIPT_DIR}/clean_cell.sh" || true
exit "${status}"

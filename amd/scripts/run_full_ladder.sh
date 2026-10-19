#!/usr/bin/env bash
# Dense agent ladder 44→2000 (n=45) on epyc9996 with pre/post clean gate.
# Prefer: cd amd && ./o full-ladder  (starts tmux)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${AMD_DIR}/.." && pwd)"
cd "${ROOT}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1

bash "${SCRIPT_DIR}/clean_cell.sh"
bash "${ROOT}/scripts/host/run_dense2k_9996.sh"
status=$?
bash "${SCRIPT_DIR}/clean_cell.sh" || true
exit "${status}"

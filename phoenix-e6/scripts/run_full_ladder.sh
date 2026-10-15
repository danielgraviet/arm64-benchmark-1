#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1
bash "${SCRIPT_DIR}/clean_cell.sh"
bash "${ROOT}/scripts/host/run_dense2k_9j45.sh"
status=$?
bash "${SCRIPT_DIR}/clean_cell.sh" || true
exit "${status}"

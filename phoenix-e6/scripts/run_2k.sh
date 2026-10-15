#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1
export TARGET=phoenix-e6
bash "${SCRIPT_DIR}/clean_cell.sh"
TARGET=phoenix-e6 bash "${ROOT}/scripts/host/run_create_ready.sh" 2000
status=$?
bash "${SCRIPT_DIR}/clean_cell.sh" || true
exit "${status}"

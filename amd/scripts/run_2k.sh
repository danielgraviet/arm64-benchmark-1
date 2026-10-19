#!/usr/bin/env bash
# Create-ready 2000 on epyc9996 with pre/post clean gate.
# Prefer: cd amd && ./o 2k  (starts tmux)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${AMD_DIR}/.." && pwd)"
cd "${ROOT}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1
export TARGET=epyc9996

bash "${SCRIPT_DIR}/clean_cell.sh"
TARGET=epyc9996 bash "${ROOT}/scripts/host/run_create_ready.sh" 2000
status=$?
bash "${SCRIPT_DIR}/clean_cell.sh" || true
exit "${status}"

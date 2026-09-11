#!/usr/bin/env bash
# Create-ready fleet: N parallel creates + `echo ready`, ulimit pinned to Vera 65536.
# Usage:
#   tmux new-session -d -s zen5-create2k bash scripts/host/run_create_ready.sh 2000
#   bash scripts/host/run_create_ready.sh 1000
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

COUNT="${1:-2000}"
WORKERS="${2:-${COUNT}}"
LOG="${LOG:-/tmp/zen5-create-ready-${COUNT}.log}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
export REDSWITCHES_RLP_API_URL="${REDSWITCHES_RLP_API_URL:-http://127.0.0.1:8088}"
export REDSWITCHES_RLP_TOOLBOX_URL="${REDSWITCHES_RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-4096}"

ulimit -n 65536

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

{
  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target redswitches
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) ulimit=$(ulimit -Sn) ==="
  set +e
  uv run python scripts/rlp_light_create_fleet.py \
    --target redswitches \
    --count "${COUNT}" \
    --workers "${WORKERS}" \
    --image dtgraviet/vera-agent-benchmark:v3 \
    --probe "echo ready"
  status=$?
  echo "END_EXIT=${status}"
  exit "${status}"
} 2>&1 | tee "${LOG}"
exit "${PIPESTATUS[0]}"

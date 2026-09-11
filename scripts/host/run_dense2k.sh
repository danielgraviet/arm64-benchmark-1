#!/usr/bin/env bash
# Zen5 dense ladder: match Vera n=45 / 0.025 cpu / 64 MiB, 44→2000 hold-then-exec.
# Run on the DUT only. Start under tmux:
#   tmux new-session -d -s zen5-dense2k bash scripts/host/run_dense2k.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
export REDSWITCHES_RLP_API_URL="${REDSWITCHES_RLP_API_URL:-http://127.0.0.1:8088}"
export REDSWITCHES_RLP_TOOLBOX_URL="${REDSWITCHES_RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"

LOG="${LOG:-/tmp/zen5-dense2k-n45.log}"
ulimit -n 1048576

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
  uv run main.py \
    --benchmark agent --runner rlp --target redswitches \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 44 88 176 352 528 704 880 1056 1408 1760 2000 \
    --n 45 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.025 --rlp-cpu-max 1 \
    --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 1
  status=$?
  echo "END_EXIT=${status}"
  exit "${status}"
} 2>&1 | tee "${LOG}"
exit "${PIPESTATUS[0]}"

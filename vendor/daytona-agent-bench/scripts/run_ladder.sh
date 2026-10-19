#!/usr/bin/env bash
# Dual-socket 9755 packed agent ladder. Match Vera / 9J45 n=50 maxpack.
# Do not change --n. n=45 is a different single-socket recipe.
#
#   tmux new-session -d -s agent-ladder bash scripts/run_ladder.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
export RLP_API_URL="${RLP_API_URL:-http://127.0.0.1:8088}"
export RLP_TOOLBOX_URL="${RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"

LOG="${LOG:-/tmp/agent-ladder.log}"
OUT="${ROOT}/results/agent_hold_then_exec.jsonl"
ulimit -n 1048576

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

mkdir -p "${ROOT}/results"
if [[ -f "${OUT}" ]]; then
  stamp="$(date -u +%Y%m%d_%H%M%S)"
  cp "${OUT}" "${ROOT}/results/agent_hold_then_exec_${stamp}.jsonl"
fi

{
  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  uv run python scripts/cleanup_sandboxes.py --target local
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) ulimit=$(ulimit -Sn) ==="
  set +e
  uv run main.py \
    --benchmark agent --runner rlp --target local \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 44 88 176 352 528 704 880 1056 1408 1760 2000 \
    --n 50 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.125 --rlp-cpu-max 1 \
    --rlp-memory 0.5 --rlp-memory-max 4 --rlp-disk 1 \
    --output "${OUT}"
  status=$?
  echo "END_EXIT=${status}"
  echo "wrote ${OUT}"
  exit "${status}"
} 2>&1 | tee "${LOG}"
exit "${PIPESTATUS[0]}"

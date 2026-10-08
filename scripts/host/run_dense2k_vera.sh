#!/usr/bin/env bash
# OCI / onsite Vera dense ladder: n=45 / 0.025 cpu / max1 / mem_max 4, 44→2000.
# Matches daniel-focus-here/vera-jsonl dense source (peak ~13.3 jobs/s @ 352).
#
# Run on the Vera node only, under tmux:
#   tmux new-session -d -s vera-dense bash scripts/host/run_dense2k_vera.sh
#
# CREATE pickup is hard-capped at 60s in-cell.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
export UV_NO_SYNC=1

export RLP_API_URL="${RLP_API_URL:-http://127.0.0.1:8088}"
export RLP_TOOLBOX_URL="${RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"
export VERA_RLP_API_URL="${VERA_RLP_API_URL:-http://127.0.0.1:8088}"
export VERA_RLP_TOOLBOX_URL="${VERA_RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"
export VERA_RLP_TARGET="${VERA_RLP_TARGET:-vera}"
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-8192}"
export RLP_HOLD_CREATE_BATCH="${RLP_HOLD_CREATE_BATCH:-512}"

STAMP="$(date -u +%Y%m%d_%H%M%S)"
LOG="${LOG:-/tmp/vera-dense2k-n45.log}"
LOG_NVME="${LOG_NVME:-/mnt/data/bench-logs/vera-dense2k-${STAMP}.log}"
if [[ -n "${OCI_VERA:-}" ]]; then
  OUT="daniel-focus-here/oci-vera-jsonl/concurrency_${STAMP}_n45.jsonl"
else
  OUT="daniel-focus-here/vera-jsonl/concurrency_${STAMP}_n45.jsonl"
fi
OUT_DATA="data/agent/rlp-vera-c0p025-max1/concurrency_${STAMP}_n45.jsonl"
ulimit -n 1048576 || true

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

# Re-pin after .env — never allow a laptop tunnel URL to stick.
export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export VERA_RLP_API_URL="http://127.0.0.1:8088"
export VERA_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export VERA_RLP_TARGET="vera"
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-8192}"
export RLP_HOLD_CREATE_BATCH="${RLP_HOLD_CREATE_BATCH:-512}"

if ! UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'; then
  echo "eng rlp-sdk missing. reinstalling editable client."
  UV_NO_SYNC=1 uv pip install -e "${HOME}/rlp/clients/python"
  UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'
fi

mkdir -p "$(dirname "${OUT}")" "$(dirname "${OUT_DATA}")"
mkdir -p "$(dirname "${LOG_NVME}")" 2>/dev/null || true

{
  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target vera
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) target=vera ulimit=$(ulimit -Sn) http_pool=${RLP_HTTP_MAX_CONNECTIONS} output=${OUT} ==="
  set +e
  UV_NO_SYNC=1 uv run main.py \
    --benchmark agent --runner rlp --target vera \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 44 88 176 352 528 704 880 1056 1408 1760 2000 \
    --n 45 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.025 --rlp-cpu-max 1 \
    --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 \
    --output "${OUT}"
  status=$?
  if [[ "${status}" -eq 0 && -f "${OUT}" ]]; then
    cp -f "${OUT}" "${OUT_DATA}"
    echo "MIRRORED=${OUT_DATA}"
  fi
  echo "END_EXIT=${status}"
  exit "${status}"
} 2>&1 | tee "${LOG}"
status="${PIPESTATUS[0]}"
if [[ -d "$(dirname "${LOG_NVME}")" ]]; then
  cp -f "${LOG}" "${LOG_NVME}" 2>/dev/null || true
  echo "LOG_NVME=${LOG_NVME}" >>"${LOG}"
fi
exit "${status}"

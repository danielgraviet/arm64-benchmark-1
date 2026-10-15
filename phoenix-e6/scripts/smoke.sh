#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1
export PYTHONUNBUFFERED=1
TARGET=phoenix-e6

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"

key="${RLP_API_KEY:-}"
key_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${key}" \
  http://127.0.0.1:8088/vms || echo 000)"
echo "api key probe: HTTP ${key_code} (key length ${#key}) target=${TARGET}"
[[ "${key_code}" == "200" ]] || { echo "key probe failed" >&2; exit 1; }

ulimit -n 1048576 || true
OUT="/tmp/phoenix-e6-smoke-$(date -u +%Y%m%d_%H%M%S).jsonl"
echo "smoke: one sandbox → ${OUT}"
UV_NO_SYNC=1 uv run main.py \
  --benchmark agent --runner rlp --target "${TARGET}" \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 1 --n 1 --seed 42 -E 1 --hold-then-exec \
  --rlp-cpu 0.025 --rlp-cpu-max 1 \
  --rlp-memory 0.0625 --rlp-memory-max 0.5 --rlp-disk 1 \
  --output "${OUT}"

bash "${SCRIPT_DIR}/clean_cell.sh"
echo "smoke ok"

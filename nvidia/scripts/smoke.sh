#!/usr/bin/env bash
# One-sandbox smoke after reminting key probe if needed.
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
export PYTHONUNBUFFERED=1

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_API_URL="http://127.0.0.1:8088"
export REDSWITCHES_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_REGION="${TARGET}"

key="${RLP_API_KEY:-}"
key_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${key}" \
  http://127.0.0.1:8088/vms || echo 000)"
echo "api key probe: HTTP ${key_code} (key length ${#key}) target=${TARGET}"
if [[ "${key_code}" != "200" ]]; then
  echo "key probe failed — re-run ./o start (or mint a key into .env)" >&2
  exit 1
fi

# Sync proxy DB URL with API (same fix as OCI Vera smoke).
db_url="$(sudo -n grep -E '^DATABASE_URL=' /etc/rlp/api.env 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
if [[ -n "${db_url}" ]]; then
  if sudo -n grep -q '^RLP_DB_URL=' /etc/rlp/proxy.env 2>/dev/null; then
    sudo -n sed -i "s|^RLP_DB_URL=.*|RLP_DB_URL=${db_url}|" /etc/rlp/proxy.env
  else
    echo "RLP_DB_URL=${db_url}" | sudo -n tee -a /etc/rlp/proxy.env >/dev/null
  fi
  sudo -n systemctl restart rlp-proxy
  echo "restarted rlp-proxy with the API database URL"
  sleep 2
fi

ulimit -n 1048576 || true
OUT="/tmp/zen5-smoke-$(date -u +%Y%m%d_%H%M%S).jsonl"
echo "smoke: one sandbox create+hold-then-exec → ${OUT}"
UV_NO_SYNC=1 uv run main.py \
  --benchmark agent --runner rlp --target "${TARGET}" \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 1 --n 1 --seed 42 -E 1 --hold-then-exec \
  --rlp-cpu 0.025 --rlp-cpu-max 1 \
  --rlp-memory 0.0625 --rlp-memory-max 0.5 --rlp-disk 1 \
  --output "${OUT}"

bash "${SCRIPT_DIR}/clean_cell.sh"
echo "smoke ok"

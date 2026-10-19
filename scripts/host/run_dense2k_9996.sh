#!/usr/bin/env bash
# Zen5 9996 dense ladder: match Vera n=45 / 0.025 cpu / 64 MiB, 44→2000 hold-then-exec.
# Primary deliverable: daniel-focus-here/zen5-9996-jsonl/
# Also mirrors under data/agent/ for eda --include (keeps 9575F series separate).
# Run on the DUT only. Start under tmux:
#   tmux new-session -d -s zen5-dense2k bash scripts/host/run_dense2k.sh
#
# Eng (2026-09): --target epyc9996, localhost API, dtn_ cell key, HTTP pool 8192.
# CREATE pickup is hard-capped at 60s in-cell (RLP_CREATE_MAX_QUEUE_SECS ignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
# On-box only. Eng: a locally-minted key against a remote API URL → mass 401.
export RLP_API_URL="${RLP_API_URL:-http://127.0.0.1:8088}"
export RLP_TOOLBOX_URL="${RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"
export REDSWITCHES_RLP_API_URL="${REDSWITCHES_RLP_API_URL:-http://127.0.0.1:8088}"
export REDSWITCHES_RLP_TOOLBOX_URL="${REDSWITCHES_RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"
export REDSWITCHES_RLP_REGION="${REDSWITCHES_RLP_REGION:-epyc9996}"
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-8192}"
# Hold-then-exec create waves (match raised RLP_VM_CONCURRENCY on this cell).
export RLP_HOLD_CREATE_BATCH="${RLP_HOLD_CREATE_BATCH:-512}"

STAMP="$(date -u +%Y%m%d_%H%M%S)"
LOG="${LOG:-/tmp/zen5-dense2k-n45.log}"
LOG_NVME="${LOG_NVME:-/mnt/data/bench-logs/zen5-dense2k-${STAMP}.log}"
OUT="daniel-focus-here/zen5-9996-jsonl/concurrency_${STAMP}_n45.jsonl"
OUT_DATA="data/agent/rlp-epyc9996-c0p025-max1/concurrency_${STAMP}_n45.jsonl"
ulimit -n 1048576

# Keep eng editable rlp-sdk (cpu_max / memory_max). Bare uv run reverts to PyPI.
export UV_NO_SYNC=1

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

# Re-pin after .env — earlier Mac .env copies pointed RLP_* at the public API.
export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_API_URL="http://127.0.0.1:8088"
export REDSWITCHES_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_REGION="epyc9996"
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-8192}"
export RLP_HOLD_CREATE_BATCH="${RLP_HOLD_CREATE_BATCH:-512}"

if ! UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'; then
  echo "eng rlp-sdk missing cpu_max. Run: bash scripts/host/install_eng_rlp_sdk.sh" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT}")" "$(dirname "${OUT_DATA}")"
mkdir -p "$(dirname "${LOG_NVME}")" 2>/dev/null || true
# drop placeholder once real results exist
rm -f daniel-focus-here/zen5-9996-jsonl/.gitkeep

{
  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) ulimit=$(ulimit -Sn) http_pool=${RLP_HTTP_MAX_CONNECTIONS} output=${OUT} UV_NO_SYNC=${UV_NO_SYNC} ==="
  # First miss does not build unless RLP_TEMPLATE_BUILD_AFTER=1 (needed for
  # template=hit boot-phases during hold-then-exec creates).
  if [[ -f /etc/rlp/runner.env ]] \
    && ! sudo -n grep -qE '^RLP_TEMPLATE_BUILD_AFTER=1$' /etc/rlp/runner.env 2>/dev/null; then
    echo "setting RLP_TEMPLATE_BUILD_AFTER=1 for snapshot template builds"
    if sudo -n grep -qE '^RLP_TEMPLATE_BUILD_AFTER=' /etc/rlp/runner.env 2>/dev/null; then
      sudo -n sed -i 's/^RLP_TEMPLATE_BUILD_AFTER=.*/RLP_TEMPLATE_BUILD_AFTER=1/' /etc/rlp/runner.env
    else
      echo 'RLP_TEMPLATE_BUILD_AFTER=1' | sudo -n tee -a /etc/rlp/runner.env >/dev/null
    fi
    sudo -n systemctl restart rlp-runner
    sleep 3
    systemctl is-active rlp-runner >/dev/null
  fi
  fleet_since="$(date -u '+%Y-%m-%d %H:%M:%S')"
  set +e
  UV_NO_SYNC=1 uv run main.py \
    --benchmark agent --runner rlp --target epyc9996 \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 44 88 176 352 528 704 880 1056 1408 1760 2000 \
    --n 45 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.025 --rlp-cpu-max 1 \
    --rlp-memory 0.0625 --rlp-memory-max 0.5 --rlp-disk 1 \
    --output "${OUT}"
  status=$?
  # Scrape create boot-phases (scratch/disk, mem load, FC, toolbox) across the
  # ladder's hold-then-exec creates into the same JSONL as agent metrics.
  fleet_log="$(sudo -n journalctl -u rlp-runner --since "${fleet_since}" --no-pager -o cat 2>/dev/null || true)"
  hits="$(printf '%s\n' "${fleet_log}" | grep -c 'template=hit' || true)"
  misses="$(printf '%s\n' "${fleet_log}" | grep -c 'template=miss' || true)"
  echo "template_hit=${hits} template_miss=${misses}"
  journal_txt="/tmp/epyc9996-dense-fleet-journal.txt"
  printf '%s\n' "${fleet_log}" > "${journal_txt}"
  if [[ -f "${OUT}" ]]; then
    python3 "${ROOT}/scripts/host/scrape_boot_phases.py" "${journal_txt}" "${OUT}" || true
  fi
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

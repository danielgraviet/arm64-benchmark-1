#!/usr/bin/env bash
# Create-ready fleet: match Vera create-ready client knobs exactly.
# Vera meta (2026-09-08 clean 1000): cpu=0.025 mem=0.0625 disk=1,
# ulimit_nofile=65536, http_max_connections=1024, probe='echo ready',
# image dtgraviet/vera-agent-benchmark:v3, workers=count.
#
# Usage (on DUT):
#   tmux new-session -d -s zen5-create1k bash scripts/host/run_create_ready.sh 1000
#   tmux new-session -d -s zen5-create2k bash scripts/host/run_create_ready.sh 2000
#   TARGET=epyc9755 bash scripts/host/run_create_ready.sh 1000   # 9755 box
#   TARGET=epyc9575 bash scripts/host/run_create_ready.sh 2000   # 9575F box (default)
#   TARGET=vera bash scripts/host/run_create_ready.sh 1000       # OCI / onsite Vera
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

COUNT="${1:-1000}"
WORKERS="${2:-${COUNT}}"
TARGET="${TARGET:-epyc9575}"
case "${TARGET}" in
  epyc9575) OUT_DIR="daniel-focus-here/zen5-9575f-jsonl" ;;
  epyc9755) OUT_DIR="daniel-focus-here/zen5-9755-jsonl" ;;
  vera) OUT_DIR="daniel-focus-here/vera-jsonl" ;;
  *) OUT_DIR="results/zen5-jsonl" ;;
esac
LOG="${LOG:-/tmp/${TARGET}-create-ready-${COUNT}.log}"
LOG_NVME="${LOG_NVME:-/mnt/data/bench-logs/${TARGET}-create-ready-${COUNT}-$(date -u +%Y%m%d_%H%M%S).log}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
# On-box cell routing (not a laptop tunnel).
export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_API_URL="http://127.0.0.1:8088"
export REDSWITCHES_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_REGION="${TARGET}"
export VERA_RLP_API_URL="http://127.0.0.1:8088"
export VERA_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export VERA_RLP_TARGET="vera"
# Client HTTP pool:
#   Vera onsite 1k used 1024; Vera 2k used 4096.
#   Zen5 create-ready needs 4096 (1024 starves wait-poll on slower ready path).
if [[ -z "${RLP_HTTP_MAX_CONNECTIONS:-}" ]]; then
  if [[ "${TARGET}" == "vera" && "${COUNT}" -le 1000 ]]; then
    export RLP_HTTP_MAX_CONNECTIONS=1024
  else
    export RLP_HTTP_MAX_CONNECTIONS=4096
  fi
fi
export UV_NO_SYNC=1

# Vera create-ready FD budget.
ulimit -n 65536 || true

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

# Re-pin after .env (do not let .env drop URLs or the pool).
export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_API_URL="http://127.0.0.1:8088"
export REDSWITCHES_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_REGION="${TARGET}"
export VERA_RLP_API_URL="http://127.0.0.1:8088"
export VERA_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export VERA_RLP_TARGET="vera"
# Force create-ready pool after .env (onsite Vera 1k=1024, Vera 2k/Zen5=4096).
# Override with CREATE_READY_HTTP_POOL=N if needed.
if [[ -n "${CREATE_READY_HTTP_POOL:-}" ]]; then
  export RLP_HTTP_MAX_CONNECTIONS="${CREATE_READY_HTTP_POOL}"
elif [[ "${TARGET}" == "vera" && "${COUNT}" -le 1000 ]]; then
  export RLP_HTTP_MAX_CONNECTIONS=1024
else
  export RLP_HTTP_MAX_CONNECTIONS=4096
fi

# Onsite recipe is 1 GiB/sandbox, fully allocated by mkfs.ext4.
# OCI Vera's root disk is ~98 GB, so 1000 x 1 GiB cannot fit.
# 16 MiB x 1000 = 16 GB. 16 MiB x 2000 = 32 GB. Both fit in ~71 GB free.
if [[ "${TARGET}" == "vera" ]]; then
  DISK_GB="${DISK_GB:-0.015625}"
else
  DISK_GB="${DISK_GB:-1.0}"
fi

if [[ "${TARGET}" == "vera" && -f /etc/rlp/api.env ]]; then
  if ! sudo -n grep -q '^RLP_MIN_SCRATCH_MIB=16$' /etc/rlp/api.env 2>/dev/null; then
    echo "lowering RLP_MIN_SCRATCH_MIB to 16 so the API does not clamp disks back to 1 GiB"
    sudo -n sed -i '/^RLP_MIN_SCRATCH_MIB=/d' /etc/rlp/api.env
    echo 'RLP_MIN_SCRATCH_MIB=16' | sudo -n tee -a /etc/rlp/api.env >/dev/null
    sudo -n systemctl restart rlp-api
    for _ in $(seq 1 30); do
      curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break
      sleep 1
    done
  fi
fi

# int(0.015625)*1024 is 0. The API then 400s every create. Round like mem_mib.
patch_scratch_mib() {
  python3 - <<'PY'
from pathlib import Path
p = Path.home() / "rlp/clients/python/src/rlp/daytona.py"
if not p.is_file():
    raise SystemExit(0)
text = p.read_text()
old = 'body["scratch_mib"] = int(r.disk) * 1024'
new = 'body["scratch_mib"] = int(round(float(r.disk) * 1024))'
if old not in text:
    raise SystemExit(0)
p.write_text(text.replace(old, new, 1))
print("patched scratch_mib")
raise SystemExit(2)
PY
}

sdk_ok() {
  UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'
}

if patch_scratch_mib; then
  :
else
  patch_rc=$?
  if [[ "${patch_rc}" -eq 2 ]]; then
    UV_NO_SYNC=1 uv pip install -e "${HOME}/rlp/clients/python"
  else
    exit "${patch_rc}"
  fi
fi

if ! sdk_ok; then
  echo "eng rlp-sdk missing (uv sync drops cpu_max). reinstalling editable client."
  if [[ -d "${HOME}/rlp/clients/python" ]]; then
    UV_NO_SYNC=1 uv pip install -e "${HOME}/rlp/clients/python"
  else
    if [[ -f "${ROOT}/.env.oci" ]]; then
      set -a
      # shellcheck disable=SC1091
      source "${ROOT}/.env.oci"
      set +a
    fi
    RLP_ROOT="${HOME}/rlp" bash "${ROOT}/scripts/host/install_eng_rlp_sdk.sh"
  fi
  if ! sdk_ok; then
    echo "eng rlp-sdk still missing cpu_max" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "${LOG_NVME}")" 2>/dev/null || true
mkdir -p "${OUT_DIR}"

STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUTPUT="${OUT_DIR}/${TARGET}_create_ready_${COUNT}_${STAMP}.jsonl"

# Onsite ~10s/1000 is template resume. A 1000-wide burst all misses the
# template and cold-boots (~35/s here). Build one template first.
if [[ "${TARGET}" == "vera" ]]; then
  sudo -n mkdir -p /etc/systemd/system/rlp-runner.service.d
  sudo -n tee /etc/systemd/system/rlp-runner.service.d/snapshots.conf >/dev/null <<'EOF'
[Service]
Environment=RLP_SNAPSHOTS=1
Environment=RLP_VM_CONCURRENCY=256
Environment=RLP_NETNS_POOL=2100
Environment=RLP_MAX_LIVE_VMS=3000
EOF
  if ! sudo -n cat "/proc/$(pgrep -nx rlp-runner)/environ" 2>/dev/null | tr '\0' '\n' | grep -qx 'RLP_SNAPSHOTS=1'; then
    echo "restarting runner with snapshots enabled"
    sudo -n systemctl daemon-reload
    sudo -n systemctl restart rlp-runner
    sleep 5
  fi
fi

{
  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}"
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) target=${TARGET} ulimit=$(ulimit -Sn) count=${COUNT} workers=${WORKERS} http_pool=${RLP_HTTP_MAX_CONNECTIONS} disk_gb=${DISK_GB} ==="
  if [[ "${TARGET}" == "vera" && "${COUNT}" -gt 1 ]]; then
    echo "=== WARMUP $(date -u +%Y-%m-%dT%H:%M:%SZ) one sandbox to build the snapshot template ==="
    UV_NO_SYNC=1 uv run python scripts/rlp_light_create_fleet.py \
      --target "${TARGET}" \
      --count 1 \
      --workers 1 \
      --image dtgraviet/vera-agent-benchmark:v3 \
      --cpu 0.025 \
      --memory 0.0625 \
      --disk "${DISK_GB}" \
      --probe "echo ready" \
      --output "/tmp/vera-template-warmup.jsonl" || true
    echo "waiting for template build ready"
    ready=0
    for _ in $(seq 1 90); do
      if sudo -n journalctl -u rlp-runner --since "5 min ago" --no-pager 2>/dev/null | grep -q "template build ready"; then
        ready=1
        break
      fi
      if sudo -n journalctl -u rlp-runner --since "5 min ago" --no-pager 2>/dev/null | grep -q "template build failed"; then
        echo "template build failed"
        sudo -n journalctl -u rlp-runner --since "5 min ago" --no-pager 2>/dev/null | grep "template build failed" | tail -n 3
        break
      fi
      sleep 2
    done
    echo "template_ready=${ready}"
    UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}" || true
  fi
  set +e
  UV_NO_SYNC=1 uv run python scripts/rlp_light_create_fleet.py \
    --target "${TARGET}" \
    --count "${COUNT}" \
    --workers "${WORKERS}" \
    --image dtgraviet/vera-agent-benchmark:v3 \
    --cpu 0.025 \
    --memory 0.0625 \
    --disk "${DISK_GB}" \
    --probe "echo ready" \
    --output "${OUTPUT}"
  status=$?
  echo "END_EXIT=${status}"
  echo "OUTPUT=${OUTPUT}"
  exit "${status}"
} 2>&1 | tee "${LOG}"
status="${PIPESTATUS[0]}"
if [[ -d "$(dirname "${LOG_NVME}")" ]]; then
  cp -f "${LOG}" "${LOG_NVME}" 2>/dev/null || true
  echo "LOG_NVME=${LOG_NVME}" >>"${LOG}"
fi
exit "${status}"

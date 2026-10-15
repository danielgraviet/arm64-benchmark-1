#!/usr/bin/env bash
# Zen5 9J45 (phoenix-e6) dense ladder: match Vera/9755 n=45 / 0.025 cpu / 64 MiB,
# 44→2000 hold-then-exec, pinned to NUMA socket 0.
# Primary deliverable: daniel-focus-here/zen5-9j45-jsonl/
# Mirror: data/agent/rlp-phoenix-e6-c0p025-max1/
# Run on the DUT only. Start under tmux:
#   tmux new-session -d -s zen5-dense2k bash scripts/host/run_dense2k_9j45.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

TARGET="phoenix-e6"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
export RLP_API_URL="${RLP_API_URL:-http://127.0.0.1:8088}"
export RLP_TOOLBOX_URL="${RLP_TOOLBOX_URL:-http://127.0.0.1:9000/toolbox}"
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-8192}"
export RLP_HOLD_CREATE_BATCH="${RLP_HOLD_CREATE_BATCH:-512}"

STAMP="$(date -u +%Y%m%d_%H%M%S)"
LOG="${LOG:-/tmp/zen5-9j45-dense2k-n45.log}"
LOG_NVME="${LOG_NVME:-/mnt/data/bench-logs/zen5-9j45-dense2k-${STAMP}.log}"
OUT="daniel-focus-here/zen5-9j45-jsonl/concurrency_${STAMP}_n45.jsonl"
OUT_DATA="data/agent/rlp-phoenix-e6-c0p025-max1/concurrency_${STAMP}_n45.jsonl"
ulimit -n 1048576

export UV_NO_SYNC=1

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-8192}"
export RLP_HOLD_CREATE_BATCH="${RLP_HOLD_CREATE_BATCH:-512}"

if ! UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'; then
  echo "eng rlp-sdk missing cpu_max. Run: bash scripts/host/install_eng_rlp_sdk.sh" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT}")" "$(dirname "${OUT_DATA}")"
mkdir -p "$(dirname "${LOG_NVME}")" 2>/dev/null || true

{
  echo "=== PIN SOCKET 0 $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  want_cpus="$(tr -d '[:space:]' </sys/devices/system/node/node0/cpulist 2>/dev/null || true)"
  want_cpus="${want_cpus:-0-95,192-287}"
  want_mems="0"
  current_cpus="$(tr -d '[:space:]' </sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null || true)"
  current_mems="$(tr -d '[:space:]' </sys/fs/cgroup/rlp.slice/cpuset.mems 2>/dev/null || true)"
  if [[ -z "${current_cpus}" ]]; then
    current_cpus="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null | tr -d '[:space:]' || true)"
    current_mems="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.mems 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ "${current_cpus}" == "${want_cpus}" && "${current_mems}" == "${want_mems}" ]]; then
    echo "already pinned to socket 0. not restarting the runner."
    SOCKET_PIN_CPUS="${current_cpus}"
    SOCKET_PIN_MEMS="${current_mems}"
  else
    bash "${ROOT}/tickets/9j45-pin-single-socket.sh" 0
    SOCKET_PIN_CPUS="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null | tr -d '[:space:]' || true)"
    SOCKET_PIN_MEMS="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.mems 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ "${SOCKET_PIN_CPUS}" != "${want_cpus}" || "${SOCKET_PIN_MEMS}" != "${want_mems}" ]]; then
    echo "refusing dense ladder: pin is cpus=${SOCKET_PIN_CPUS} mems=${SOCKET_PIN_MEMS}, want ${want_cpus}/${want_mems}" >&2
    exit 1
  fi
  export SOCKET_PIN_CPUS SOCKET_PIN_MEMS
  echo "PINNED cpus=${SOCKET_PIN_CPUS} mems=${SOCKET_PIN_MEMS}"

  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}"
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) ulimit=$(ulimit -Sn) http_pool=${RLP_HTTP_MAX_CONNECTIONS} output=${OUT} UV_NO_SYNC=${UV_NO_SYNC} ==="
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
    --benchmark agent --runner rlp --target "${TARGET}" \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 44 88 176 352 528 704 880 1056 1408 1760 2000 \
    --n 45 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.025 --rlp-cpu-max 1 \
    --rlp-memory 0.0625 --rlp-memory-max 0.5 --rlp-disk 1 \
    --output "${OUT}"
  status=$?
  fleet_log="$(sudo -n journalctl -u rlp-runner --since "${fleet_since}" --no-pager -o cat 2>/dev/null || true)"
  hits="$(printf '%s\n' "${fleet_log}" | grep -c 'template=hit' || true)"
  misses="$(printf '%s\n' "${fleet_log}" | grep -c 'template=miss' || true)"
  echo "template_hit=${hits} template_miss=${misses}"
  journal_txt="/tmp/phoenix-e6-dense-fleet-journal.txt"
  printf '%s\n' "${fleet_log}" > "${journal_txt}"
  if [[ -f "${OUT}" ]]; then
    python3 "${ROOT}/scripts/host/scrape_boot_phases.py" "${journal_txt}" "${OUT}" || true
    python3 - "${OUT}" <<'PY'
import json
import os
import sys

path = sys.argv[1]
meta = None
levels = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "meta" and meta is None:
            meta = {
                "artifact": obj.get("artifact"),
                "seed": obj.get("seed"),
                "n": obj.get("n"),
                "episodes_per_sandbox": obj.get("episodes_per_sandbox"),
                "rlp_cpu": obj.get("rlp_cpu"),
                "rlp_cpu_max": obj.get("rlp_cpu_max"),
                "rlp_memory": obj.get("rlp_memory"),
                "rlp_memory_max": obj.get("rlp_memory_max"),
                "rlp_disk": obj.get("rlp_disk"),
                "hold_then_exec": obj.get("hold_then_exec"),
                "target": obj.get("target"),
                "socket_cpus": os.environ.get("SOCKET_PIN_CPUS"),
                "socket_mems": os.environ.get("SOCKET_PIN_MEMS"),
                "socket_pin": {
                    "slice_cpus": os.environ.get("SOCKET_PIN_CPUS"),
                    "slice_mems": os.environ.get("SOCKET_PIN_MEMS"),
                },
            }
        elif obj.get("type") == "summary":
            levels.append(
                {
                    "concurrency": obj.get("concurrency"),
                    "runs": obj.get("runs"),
                    "failures": obj.get("failures"),
                    "checksum_ok": obj.get("checksum_ok"),
                    "distinct_checksums": obj.get("distinct_checksums"),
                    "throughput_per_sec": obj.get("throughput_per_sec"),
                    "p50_duration_ms": obj.get("p50_duration_ms"),
                    "exec_wall_s": obj.get("exec_wall_s"),
                    "create_wall_s": obj.get("create_wall_s"),
                }
            )
record = {"type": "ladder", "meta": meta, "levels": levels}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, separators=(",", ":")) + "\n")
print("appended ladder summary with socket_pin")
PY
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

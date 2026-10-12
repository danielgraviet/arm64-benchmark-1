#!/usr/bin/env bash
# OCI / onsite Vera dense ladder: n=45 / 0.025 cpu / max1 / mem_max 4, 44→2000.
# Pins rlp.slice to socket 0 first, matching the published one-socket Vera file
# (peak ~13.3 jobs/s @ 352). Both sockets on this OCI box peaked at 26.9.
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
# Overridden after .env to the published pool of 512 unless already set.
export RLP_HTTP_MAX_CONNECTIONS="${RLP_HTTP_MAX_CONNECTIONS:-512}"
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
# Published Vera dense file used HTTP pool 512. Do not keep a create-ready pool.
export RLP_HTTP_MAX_CONNECTIONS=512
export RLP_HOLD_CREATE_BATCH=512

# Published recipe: n=45, seed 42, -E 8, hold-then-exec, cpu 0.025 / max 1,
# memory 0.0625 / max 4, levels 44 through 2000, disk 1 GiB.
# OCI root is 98 GB, so 2000 x 1 GiB does not fit. Scratch stays 16 MiB.
# Smoke is the same command for one wave at 44 sandboxes.
if [[ "${1:-}" == "smoke" ]]; then
  DENSE_LEVELS="${DENSE_LEVELS:-44}"
  DENSE_N="${DENSE_N:-1}"
fi
DENSE_LEVELS="${DENSE_LEVELS:-44 88 176 352 528 704 880 1056 1408 1760 2000}"
DENSE_N="${DENSE_N:-45}"
DENSE_DISK="${DENSE_DISK:-0.015625}"

if ! UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'; then
  echo "eng rlp-sdk missing. reinstalling editable client."
  UV_NO_SYNC=1 uv pip install -e "${HOME}/rlp/clients/python"
  UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'
fi

mkdir -p "$(dirname "${OUT}")" "$(dirname "${OUT_DATA}")"
mkdir -p "$(dirname "${LOG_NVME}")" 2>/dev/null || true

{
  echo "=== PIN SOCKET 0 $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  node0="$(tr -d '[:space:]' < /sys/devices/system/node/node0/cpulist)"
  if [[ "${node0}" != "0-87,176-263" ]]; then
    echo "refusing pin. node0 cpulist=${node0}, expected 0-87,176-263" >&2
    exit 1
  fi
  bash "${ROOT}/tickets/vera-pin-single-socket.sh" 0
  SOCKET_PIN_CPUS="$(tr -d '[:space:]' < /sys/fs/cgroup/rlp.slice/cpuset.cpus)"
  SOCKET_PIN_MEMS="$(tr -d '[:space:]' < /sys/fs/cgroup/rlp.slice/cpuset.mems)"
  export SOCKET_PIN_CPUS SOCKET_PIN_MEMS
  echo "PINNED cpus=${SOCKET_PIN_CPUS} mems=${SOCKET_PIN_MEMS}"
  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target vera
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) target=vera ulimit=$(ulimit -Sn) http_pool=${RLP_HTTP_MAX_CONNECTIONS} levels=${DENSE_LEVELS} n=${DENSE_N} disk=${DENSE_DISK} published_disk=1 output=${OUT} ==="
  set +e
  UV_NO_SYNC=1 uv run main.py \
    --benchmark agent --runner rlp --target vera \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels ${DENSE_LEVELS} \
    --n "${DENSE_N}" --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.025 --rlp-cpu-max 1 \
    --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk "${DENSE_DISK}" \
    --output "${OUT}"
  status=$?
  if [[ -f "${OUT}" ]]; then
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
                "published_disk_gib": 1.0,
                "socket_cpus": os.environ.get("SOCKET_PIN_CPUS"),
                "socket_mems": os.environ.get("SOCKET_PIN_MEMS"),
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
    fh.write(json.dumps(record) + "\n")
print("LADDER written", flush=True)
for row in levels:
    print(
        f"  c={row['concurrency']} jobs_s={row['throughput_per_sec']} "
        f"failures={row['failures']} checksum_ok={row['checksum_ok']} "
        f"p50_duration_ms={row['p50_duration_ms']}",
        flush=True,
    )
PY
  fi
  if [[ "${status}" -eq 0 && -f "${OUT}" ]]; then
    cp -f "${OUT}" "${OUT_DATA}"
    echo "MIRRORED=${OUT_DATA}"
  fi
  echo "END_EXIT=${status}"
  echo "OUTPUT=${OUT}"
  if [[ -n "${OCI_VERA:-}" ]]; then
    echo "PUSH_THIS=git add ${OUT}"
  fi
  exit "${status}"
} 2>&1 | tee "${LOG}"
status="${PIPESTATUS[0]}"
if [[ -d "$(dirname "${LOG_NVME}")" ]]; then
  cp -f "${LOG}" "${LOG_NVME}" 2>/dev/null || true
  echo "LOG_NVME=${LOG_NVME}" >>"${LOG}"
fi
exit "${status}"

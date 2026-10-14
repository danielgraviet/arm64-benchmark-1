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
  vera)
    if [[ -n "${OCI_VERA:-}" ]]; then
      OUT_DIR="daniel-focus-here/oci-vera-jsonl"
    else
      OUT_DIR="daniel-focus-here/vera-jsonl"
    fi
    ;;
  *) OUT_DIR="results/zen5-jsonl" ;;
esac
LOG="${LOG:-/tmp/${TARGET}-create-ready-${COUNT}.log}"
LOG_NVME="${LOG_NVME:-/mnt/data/bench-logs/${TARGET}-create-ready-${COUNT}-$(date -u +%Y%m%d_%H%M%S).log}"

export PATH="/usr/local/go/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"
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
  # A 1024-wide poll of GET /vms starves the API event consumer. The runner
  # already finishes a resume in tens of milliseconds. The client time is the
  # wait until that consumer marks the row started.
  export RLP_HTTP_MAX_CONNECTIONS=32
  export RLP_WAIT_POLL_START_S=0.5
  export RLP_WAIT_POLL_FACTOR=1
  export RLP_WAIT_POLL_MAX_S=0.5
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

if [[ "${TARGET}" == "vera" && -n "${OCI_VERA:-}" && -f /etc/rlp/api.env ]]; then
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

# Onsite ~11s/1000 is template resume. The runner cold-boots a miss and only
# starts a background template build on the 2nd miss (RLP_TEMPLATE_BUILD_AFTER
# default 2). One warmup is miss 1, so it never builds, and a 0.3s cold boot
# looks like a hit. Force the build on the first sandbox, then wait for it.
if [[ "${TARGET}" == "vera" ]]; then
  # The events table insert is the dominant write in each API batch. Off for
  # this benchmark. The API reads the flag once at startup, so restart if the
  # live process does not have it.
  sudo -n mkdir -p /etc/systemd/system/rlp-api.service.d
  sudo -n tee /etc/systemd/system/rlp-api.service.d/no-event-audit.conf >/dev/null <<'EOF'
[Service]
Environment=RLP_EVENT_AUDIT=0
EOF
  api_env="$(sudo -n cat "/proc/$(pgrep -nx rlp-api)/environ" 2>/dev/null | tr '\0' '\n' || true)"
  if ! printf '%s\n' "${api_env}" | grep -qx 'RLP_EVENT_AUDIT=0'; then
    echo "restarting rlp-api with event audit off"
    sudo -n systemctl daemon-reload
    sudo -n systemctl restart rlp-api
    for _ in $(seq 1 30); do
      if curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
  fi
  sudo -n mkdir -p /etc/systemd/system/rlp-runner.service.d
  sudo -n tee /etc/systemd/system/rlp-runner.service.d/snapshots.conf >/dev/null <<'EOF'
[Service]
Environment=RLP_SNAPSHOTS=1
Environment=RLP_VM_CONCURRENCY=256
Environment=RLP_NETNS_POOL=2100
Environment=RLP_MAX_LIVE_VMS=3000
Environment=RLP_TEMPLATE_BUILD_AFTER=1
Environment=RLP_QUIET_PROGRESS=1
EOF
  # Each create emits assigned, building, and booting before running. The
  # client only waits for running. Those three extra events are most of the
  # 54 started-updates per second. Skip them, keep the running event, rebuild
  # the runner once.
  quiet_built=0
  if [[ "${FORCE_RUNNER_REBUILD:-0}" == "1" ]] \
    || ! grep -a -q 'RLP_QUIET_PROGRESS' /usr/local/bin/rlp-runner 2>/dev/null \
    || ! grep -a -q 'RLP_PRIV_EXEC_CONCURRENCY' /usr/local/bin/rlp-runner 2>/dev/null; then
    echo "patching the runner to emit only the started event"
    python3 - <<'PY'
from pathlib import Path
import os
root = Path(os.environ.get("RLP_RUNNER_SOURCE", str(Path.home() / "rlp")))
p = root / "runner/internal/runner/vm.go"
if (p.parent / "classes.go").exists():
    # Current runners centralize create progress in classes.go. Preserve
    # retry errors and terminal events while suppressing plain progress.
    p = p.parent / "runner.go"
    text = p.read_text()
    if "RLP_QUIET_PROGRESS" not in text:
        signature = "func (r *Runner) emitVm(ctx context.Context, vs contract.VmState) {"
        assert signature in text
        text = text.replace(signature, signature + '''
    if envIsSet("RLP_QUIET_PROGRESS") && vs.Error == "" &&
        (vs.Status == contract.VmAssigned || vs.Status == contract.VmBuilding || vs.Status == contract.VmBooting) {
        return
    }
''', 1)
        p.write_text(text)
    print("current runner has quiet progress and native privexec limiter")
    raise SystemExit(0)
text = p.read_text()
if "RLP_QUIET_PROGRESS" not in text:
    pairs = [
        (
            '\tr.emitJob(ctx, job.JobID, "running", "")\n'
            '\tr.emitVm(ctx, contract.VmState{VmID: job.VmID, Status: contract.VmAssigned})\n',
            '\tif !envIsSet("RLP_QUIET_PROGRESS") {\n'
            '\t\tr.emitJob(ctx, job.JobID, "running", "")\n'
            '\t\tr.emitVm(ctx, contract.VmState{VmID: job.VmID, Status: contract.VmAssigned})\n'
            '\t}\n',
        ),
        (
            '\tr.emitVm(ctx, contract.VmState{VmID: job.VmID, Status: contract.VmBuilding})\n',
            '\tif !envIsSet("RLP_QUIET_PROGRESS") {\n'
            '\t\tr.emitVm(ctx, contract.VmState{VmID: job.VmID, Status: contract.VmBuilding})\n'
            '\t}\n',
        ),
        (
            '\tr.emitVm(ctx, contract.VmState{\n'
            '\t\tVmID: job.VmID, Status: contract.VmBooting, ManifestName: name,\n'
            '\t})\n',
            '\tif !envIsSet("RLP_QUIET_PROGRESS") {\n'
            '\t\tr.emitVm(ctx, contract.VmState{\n'
            '\t\t\tVmID: job.VmID, Status: contract.VmBooting, ManifestName: name,\n'
            '\t\t})\n'
            '\t}\n',
        ),
    ]
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"runner source does not match the quiet-progress patch: {old!r}")
        text = text.replace(old, new, 1)
    p.write_text(text)
print("runner source has RLP_QUIET_PROGRESS")
# Preserve the privileged-exec limiter when rebuilding the pinned eng source.
network = p.parent.parent / "vm/network.go"
src = network.read_text()
if "acquirePrivExec()" not in src:
    for signature in [
        "func run(name string, args ...string) error {",
        "func runStdin(name string, args ...string) error {",
        "func runNsNft(ns, script string) error {",
    ]:
        if signature not in src:
            raise SystemExit(f"missing privileged helper: {signature}")
        src = src.replace(signature, signature + "\n\trelease := acquirePrivExec()\n\tdefer release()", 1)
    network.write_text(src)
    (network.parent / "priv_exec_limit.go").write_text('''package vm

import (
    "os"
    "strconv"
)

var privExecSlots = make(chan struct{}, privExecLimit())

func privExecLimit() int {
    n, err := strconv.Atoi(os.Getenv("RLP_PRIV_EXEC_CONCURRENCY"))
    if err != nil || n < 1 { return 16 }
    return n
}

func acquirePrivExec() func() {
    privExecSlots <- struct{}{}
    return func() { <-privExecSlots }
}
''')
print("runner source has RLP_PRIV_EXEC_CONCURRENCY")
PY
    echo "building rlp-runner"
    (
      cd "${RLP_RUNNER_SOURCE:-${HOME}/rlp}/runner"
      export PATH="/usr/local/go/bin:${PATH}"
      if [[ ! -x /usr/local/go/bin/go ]]; then
        echo "go is not at /usr/local/go/bin/go" >&2
        exit 1
      fi
      CGO_ENABLED=0 /usr/local/go/bin/go build -o /tmp/rlp-runner ./cmd/runner
    )
    sudo -n install -m0755 -o root -g root /tmp/rlp-runner /usr/local/bin/rlp-runner
    quiet_built=1
  fi
  # Resume copies one 16 MiB scratch file per sandbox. On ext4 that is a
  # real read and write, 16 GiB for 1000, on the 98 GB root disk. The first
  # resume fleet paid that cold (46s, 21/s). The next one still wrote 16 GiB
  # and landed at 19.8s. A tmpfs keeps those copies in RAM. Mounting hides
  # the on-disk template, so the runner restarts and the warmup builds a new one.
  scratch_moved=0
  jobs_moved=0
  # POST /vms waits for the JetStream ack of the create job. JOBS is a file
  # store on the root disk, and that ack stays near 55/s after Postgres
  # synchronous_commit=off. Memory storage makes the ack a RAM write.
  jobs_storage="$(curl -fsS -m 3 'http://127.0.0.1:8222/jsz?streams=true' 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
found=""
for acct in d.get("account_details",[]):
    for s in acct.get("stream_detail",[]):
        if s.get("name")=="JOBS":
            cfg=s.get("config") or {}
            found=(cfg.get("storage") or s.get("storage") or "")
print(found)
' 2>/dev/null || true)"
  echo "jobs_storage=${jobs_storage:-unknown}"
  if [[ -z "${jobs_storage}" ]]; then
    echo "could not read JOBS storage. leaving the stream."
  elif [[ "${jobs_storage}" != "memory" && "${jobs_storage}" != "Memory" ]]; then
    nats_token="$(sudo -n grep -E '^RLP_NATS_TOKEN=' /etc/rlp/runner.env | tail -n1 | cut -d= -f2- || true)"
    if [[ -z "${nats_token}" ]]; then
      echo "no NATS token. JOBS stays on disk."
    else
      echo "recreating JOBS in memory"
      nats_box() {
        sudo -n docker run --rm --network host natsio/nats-box:latest \
          nats --server nats://127.0.0.1:4222 --token "${nats_token}" "$@"
      }
      nats_box stream rm JOBS --force || echo "JOBS remove returned non-zero"
      if nats_box stream add JOBS \
        --subjects 'jobs.>' \
        --storage memory \
        --retention work \
        --discard new \
        --max-msgs=32000 --max-bytes=-1 --max-age=0 \
        --max-msg-size=-1 --dupe-window=2m \
        --replicas 1 --defaults; then
        jobs_moved=1
      else
        echo "JOBS memory create failed"
      fi
    fi
  fi
  fstype="$(findmnt -n -o FSTYPE /scratch 2>/dev/null || true)"
  fc_n="$(pgrep -c firecracker 2>/dev/null || true)"
  fc_n="${fc_n:-0}"
  avail_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
  if [[ -z "${OCI_VERA:-}" ]]; then
    echo "HQ Vera: keeping configured scratch storage (disk_gb=${DISK_GB})"
  elif [[ "${fstype}" == "tmpfs" ]]; then
    echo "scratch fstype=tmpfs"
  elif [[ "${fc_n}" != "0" ]]; then
    echo "firecracker still running (${fc_n}). scratch stays on disk."
  elif [[ "${avail_kb:-0}" -lt 134217728 ]]; then
    echo "MemAvailable ${avail_kb:-0} KiB is under 128 GiB. scratch stays on disk."
  else
    echo "moving /scratch to a 48G tmpfs so resume copies stay in RAM"
    sudo -n mount -t tmpfs -o size=48G,mode=1777 tmpfs /scratch
    scratch_moved=1
  fi
  runner_env="$(sudo -n cat "/proc/$(pgrep -nx rlp-runner)/environ" 2>/dev/null | tr '\0' '\n' || true)"
  if [[ "${scratch_moved}" == "1" || "${jobs_moved}" == "1" || "${quiet_built}" == "1" ]] \
    || ! printf '%s\n' "${runner_env}" | grep -qx 'RLP_SNAPSHOTS=1' \
    || ! printf '%s\n' "${runner_env}" | grep -Eq '^RLP_VM_CONCURRENCY=(256|512)$' \
    || ! printf '%s\n' "${runner_env}" | grep -qx 'RLP_TEMPLATE_BUILD_AFTER=1' \
    || ! printf '%s\n' "${runner_env}" | grep -qx 'RLP_QUIET_PROGRESS=1'; then
    echo "restarting runner so the first sandbox builds a snapshot template"
    sudo -n systemctl daemon-reload
    sudo -n systemctl restart rlp-runner
  fi
    echo "waiting for netns pool"
    runner_started="$(systemctl show rlp-runner -p ActiveEnterTimestamp --value)"
    pool_ready=0
    for _ in $(seq 1 600); do
      # Namespace count includes entries still being provisioned. Use the
      # runner's ready gauge, and wait for the full pool before measuring.
      ready_ns="$(sudo -n journalctl -u rlp-runner _COMM=rlp-runner --since "${runner_started}" -n 20 --no-pager -o cat | sed -n 's/.*netns pool gauge.* ready=\([0-9]*\).*/\1/p' | tail -n1)"
      ready_ns="${ready_ns:-0}"
      echo "netns ready=${ready_ns}"
      if [[ "${ready_ns}" -ge 2100 ]]; then
        pool_ready=1
        break
      fi
      sleep 3
    done
    if [[ "${pool_ready}" != "1" ]]; then
      echo "netns pool did not become ready; refusing a hot-box measurement" >&2
      exit 1
    fi
  # GET /vms returns every historical row. 8112 deleted sandboxes is about
  # 82 pages before the fleet starts. Drop those rows. Live rows stay.
  # Each POST /vms commits one Postgres transaction. On this root disk that
  # commit waits for a sync, and the disk does about 55 of those a second.
  # The runner then resumes in ~80ms. The client's 9s median is the queue
  # for that commit, which is why slowing the status poll did not move it.
  # synchronous_commit=off returns before the disk flush. A crash can lose
  # the last moments of rows. This cell is a benchmark.
  if sudo -n docker exec rlp-postgres pg_isready -U rlp >/dev/null 2>&1; then
    echo "postgres synchronous_commit=off"
    sudo -n docker exec -i rlp-postgres psql -U rlp -d rlplatform -v ON_ERROR_STOP=1 -c \
      "ALTER SYSTEM SET synchronous_commit = off; SELECT pg_reload_conf();" \
      || echo "synchronous_commit change failed"
    echo "dropping deleted sandbox rows"
    sudo -n docker exec -i rlp-postgres psql -U rlp -d rlplatform -v ON_ERROR_STOP=1 <<'SQL' || echo "purge of deleted sandboxes failed"
DELETE FROM jobs WHERE vm_id IN (SELECT id FROM vms WHERE status = 'deleted');
DELETE FROM migrations WHERE vm_id IN (SELECT id FROM vms WHERE status = 'deleted');
DELETE FROM vms WHERE status = 'deleted';
SQL
  fi
fi

{
  echo "=== CLEANUP $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}"
  echo "FC=$(pgrep -c firecracker 2>/dev/null || true)"
  echo "=== START $(date -u +%Y-%m-%dT%H:%M:%SZ) target=${TARGET} ulimit=$(ulimit -Sn) count=${COUNT} workers=${WORKERS} http_pool=${RLP_HTTP_MAX_CONNECTIONS} disk_gb=${DISK_GB} ==="
  if [[ "${TARGET}" == "vera" && "${COUNT}" -gt 1 ]]; then
    echo "=== WARMUP $(date -u +%Y-%m-%dT%H:%M:%SZ) one sandbox to build the snapshot template ==="
    warm_log=/tmp/vera-warmup.out
    warm_since="$(date -u '+%Y-%m-%d %H:%M:%S')"
    UV_NO_SYNC=1 uv run python scripts/rlp_light_create_fleet.py \
      --target "${TARGET}" \
      --count 1 \
      --workers 1 \
      --image dtgraviet/vera-agent-benchmark:v3 \
      --cpu 0.025 \
      --memory 0.0625 \
      --disk "${DISK_GB}" \
      --probe "echo ready" \
      --output "/tmp/vera-template-warmup.jsonl" | tee "${warm_log}" || true
    if ! python3 - /tmp/vera-template-warmup.jsonl <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
summary = next(row for row in rows if row.get("type") == "summary")
raise SystemExit(0 if summary.get("ok") == 1 and summary.get("failed") == 0 else 1)
PY
    then
      echo "warmup probe failed; refusing the 1k measurement" >&2
      UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}" || true
      exit 1
    fi
    # 0.3s is a cold boot of one sandbox. template=hit in the journal is the
    # only proof the snapshot already existed. Otherwise wait for the build
    # that miss just started.
    ready=0
    warm_journal() {
      sudo -n journalctl -u rlp-runner --since "${warm_since}" --no-pager -o cat 2>/dev/null || true
    }
    if warm_journal | grep -q 'template=hit'; then
      echo "warmup used an existing template"
      ready=1
    else
      echo "waiting for template build ready"
      for _ in $(seq 1 60); do
        log="$(warm_journal)"
        if printf '%s\n' "${log}" | grep -q "template build ready"; then
          ready=1
          break
        fi
        if printf '%s\n' "${log}" | grep -q "template build failed"; then
          echo "template build failed"
          printf '%s\n' "${log}" | grep "template build failed" | tail -n 3
          break
        fi
        if printf '%s\n' "${log}" | grep -q "template build skipped"; then
          echo "template build skipped"
          printf '%s\n' "${log}" | grep "template build skipped" | tail -n 3
          break
        fi
        sleep 2
      done
    fi
    echo "template_ready=${ready}"
    UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}" || true
    if [[ "${ready}" != "1" ]]; then
      echo "template warmup failed; refusing a cold or unavailable-runner measurement" >&2
      exit 1
    fi
  fi
  if [[ "${TARGET}" == "vera" ]]; then
    echo "waiting for idle host before the fleet"
    idle=0
    for _ in $(seq 1 180); do
      load1="$(cut -d' ' -f1 /proc/loadavg)"
      fc_n="$(pgrep -c firecracker 2>/dev/null || true)"
      echo "idle load1=${load1} FC=${fc_n:-0}"
      if [[ "${fc_n:-0}" == "0" ]] && awk -v v="${load1}" 'BEGIN { exit !(v <= 20) }'; then
        idle=1
        break
      fi
      sleep 10
    done
    if [[ "${idle}" != "1" ]]; then
      echo "host did not become idle; refusing fleet measurement" >&2
      exit 1
    fi
  fi
  set +e
  fleet_since="$(date -u '+%Y-%m-%d %H:%M:%S')"
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
  if [[ "${TARGET}" == "vera" ]]; then
    fleet_log="$(sudo -n journalctl -u rlp-runner --since "${fleet_since}" --no-pager -o cat 2>/dev/null || true)"
    hits="$(printf '%s\n' "${fleet_log}" | grep -c 'template=hit' || true)"
    misses="$(printf '%s\n' "${fleet_log}" | grep -c 'template=miss' || true)"
    echo "template_hit=${hits} template_miss=${misses}"
    sync_commit="$(sudo -n docker exec rlp-postgres psql -U rlp -d rlplatform -qAt -c 'SHOW synchronous_commit;' 2>/dev/null || echo unknown)"
    echo "synchronous_commit=${sync_commit}"
    echo "jobs_storage=${jobs_storage:-unknown}"
    echo "scratch_fstype=$(findmnt -n -o FSTYPE /scratch 2>/dev/null || echo unknown)"
    printf '%s\n' "${fleet_log}" > /tmp/vera-fleet-journal.txt
    python3 - /tmp/vera-fleet-journal.txt "${OUTPUT}" <<'PY'
import json
import sys
from collections import defaultdict

phases = [
    "total_ms",
    "clone_ms",
    "netns_get_ms",
    "adopt_ms",
    "bind_ms",
    "scratch_cp_ms",
    "fc_start_ms",
    "load_ms",
    "toolbox_wait_ms",
]
queue_phases = ["deliver_ms", "emits_ms", "manifest_ms"]
provision_names = [
    "netns_get_ms",
    "adopt_ms",
    "bind_ms",
    "fc_start_ms",
    "scratch_cp_ms",
]
vals = defaultdict(list)
by_vm = {}

def field(line, name):
    key = name + "="
    at = line.find(key)
    if at < 0:
        return None
    rest = line[at + len(key) :]
    if rest.startswith('"'):
        end = rest.find('"', 1)
        return rest[1:end] if end > 0 else None
    token = rest.split()[0] if rest.split() else ""
    return token or None

def take_ms(line, name):
    raw = field(line, name)
    if raw is None:
        return None
    num = []
    for ch in raw:
        if ch.isdigit():
            num.append(ch)
        else:
            break
    if not num:
        return None
    return int("".join(num))

def vm_row(vm_id):
    row = by_vm.get(vm_id)
    if row is None:
        row = {}
        by_vm[vm_id] = row
    return row

with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if "boot-phases" not in line:
            continue
        vm_id = field(line, "vm_id")
        if "template=hit" in line:
            for name in phases:
                ms = take_ms(line, name)
                if ms is None:
                    continue
                vals[name].append(ms)
                if vm_id:
                    vm_row(vm_id)[name] = ms
        elif "boot-phases create" in line:
            for name in queue_phases:
                ms = take_ms(line, name)
                if ms is None:
                    continue
                vals[name].append(ms)
                if vm_id:
                    vm_row(vm_id)[name] = ms

def pct(xs, p):
    if not xs:
        return 0
    xs = sorted(xs)
    i = round((p / 100) * (len(xs) - 1))
    return xs[i]

def share(part, whole):
    if not whole:
        return 0.0
    return 100.0 * part / whole

n = len(vals["total_ms"])
print(f"boot_phases n={n}")
slow_name = ""
slow_p50 = -1
for name in phases:
    xs = vals[name]
    if not xs:
        continue
    p50 = pct(xs, 50)
    if p50 > slow_p50:
        slow_name = name
        slow_p50 = p50
    print(
        f"  {name} p50={p50} p95={pct(xs, 95)} max={max(xs)} sum_s={sum(xs)/1000:.1f}"
    )
if slow_name:
    print(f"slowest_p50={slow_name} {slow_p50}ms")
for name in queue_phases:
    xs = vals[name]
    if not xs:
        continue
    print(
        f"  {name} p50={pct(xs, 50)} p95={pct(xs, 95)} max={max(xs)} sum_s={sum(xs)/1000:.1f}"
    )

rows = []
wall_s = None
jsonl_path = sys.argv[2] if len(sys.argv) > 2 else ""
if jsonl_path:
    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") == "summary" and obj.get("ready_wall_s"):
                    wall_s = float(obj["ready_wall_s"])
                elif obj.get("type") == "sandbox" and obj.get("status") == "ok":
                    if obj.get("post_s") is None:
                        continue
                    rows.append(obj)
    except OSError as exc:
        print(f"WALL_SHARE jsonl unreadable: {exc}")

boot_p50 = pct(vals["total_ms"], 50) if vals["total_ms"] else 0
if wall_s:
    print(
        f"runner_boot_p50_ms={boot_p50} "
        f"runner_boot_p50_pct_of_wall={share(boot_p50 / 1000.0, wall_s):.2f}"
    )
elif vals["total_ms"] and boot_p50 < 1000:
    print(
        "gap=api_visibility runner boot p50 is under 1s. "
        "client create time is the wait until the API row says started."
    )

def finish_s(row):
    return float(row["create_s"]) + float(row.get("probe_s") or 0.0)

def client_line(label, row, wall):
    post = float(row["post_s"])
    wait = float(row["wait_s"])
    probe = float(row.get("probe_s") or 0.0)
    print(
        f"  {label} api_accept={post:.3f}s {share(post, wall):.1f}% "
        f"told_started={wait:.3f}s {share(wait, wall):.1f}% "
        f"probe={probe:.3f}s {share(probe, wall):.1f}%"
    )

def runner_bits(phases_for_vm):
    deliver = phases_for_vm.get("deliver_ms")
    total = phases_for_vm.get("total_ms")
    load = phases_for_vm.get("load_ms")
    toolbox = phases_for_vm.get("toolbox_wait_ms")
    provisioning = 0
    have_provision = False
    for name in provision_names:
        if name in phases_for_vm:
            provisioning += phases_for_vm[name]
            have_provision = True
    other = None
    if total is not None:
        named = (load or 0) + (toolbox or 0) + (provisioning if have_provision else 0)
        other = max(0, total - named)
    return deliver, provisioning if have_provision else None, load, toolbox, other, total

def runner_line(label, phases_for_vm, wait_s):
    deliver, provisioning, load, toolbox, other, _total = runner_bits(phases_for_vm)
    parts = [
        ("queued_before_runner", deliver),
        ("provisioning", provisioning),
        ("memory_move", load),
        ("guest_ready", toolbox),
        ("other", other),
    ]
    bits = []
    for name, ms in parts:
        if ms is None:
            continue
        sec = ms / 1000.0
        bits.append(f"{name}={sec:.3f}s {share(sec, wait_s):.1f}% of wait")
    if bits:
        print(f"  {label} " + " ".join(bits))

if wall_s and rows:
    ordered = sorted(rows, key=finish_s)
    last = ordered[-1]
    median = ordered[(len(ordered) - 1) // 2]
    print(f"WALL_SHARE wall_s={wall_s:.3f} n={len(rows)}")
    client_line("last", last, wall_s)
    client_line("median", median, wall_s)
    joined = 0
    for row in (last, median):
        sid = str(row.get("sandbox_id") or "")
        if sid and sid in by_vm:
            joined += 1
    if joined:
        print("WALL_SHARE runner joined to client ids")
        for label, row in (("last", last), ("median", median)):
            sid = str(row.get("sandbox_id") or "")
            hit = by_vm.get(sid)
            if not hit:
                print(f"  {label} no runner line for {sid}")
                continue
            runner_line(label, hit, float(row["wait_s"]))
    else:
        print("WALL_SHARE runner not joined. fleet p50 follows.")
        fleet = {name: pct(vals[name], 50) for name in phases + queue_phases if vals[name]}
        wait_med = float(median["wait_s"])
        runner_line("fleet_p50", fleet, wait_med)

# If a step holds a global kernel lock, the fleet wall is about
# count times that step, not the per-sandbox time. Network setup is the
# step the create path is expected to serialize. Memory move and guest
# boot can overlap.
serial_n = n or len(rows)
serial_buckets = [
    ("network", ["netns_get_ms", "adopt_ms", "bind_ms"]),
    ("scratch_disk", ["scratch_cp_ms"]),
    ("memory_move", ["load_ms"]),
    ("boot_until_ready", ["fc_start_ms", "toolbox_wait_ms"]),
]
if serial_n:
    print(f"SERIAL_SHARE n={serial_n} p50 times count, if that step cannot overlap")
    for label, names in serial_buckets:
        ms = 0
        seen = False
        for name in names:
            if vals[name]:
                ms += pct(vals[name], 50)
                seen = True
        if not seen:
            continue
        sec = serial_n * ms / 1000.0
        if wall_s:
            print(f"  {label} {sec:.1f}s {share(sec, wall_s):.0f}% of wall")
        else:
            print(f"  {label} {sec:.1f}s")

record = {
    "type": "wall_share",
    "wall_s": wall_s,
    "runner_boot_p50_ms": boot_p50,
    "runner_boot_p50_pct_of_wall": (
        share(boot_p50 / 1000.0, wall_s) if wall_s else None
    ),
    "phase_p50_ms": {name: pct(vals[name], 50) for name in phases + queue_phases if vals[name]},
}
if wall_s and rows:
    ordered = sorted(rows, key=finish_s)
    last = ordered[-1]
    median = ordered[(len(ordered) - 1) // 2]

    def client_rec(row):
        post = float(row["post_s"])
        wait = float(row["wait_s"])
        probe = float(row.get("probe_s") or 0.0)
        return {
            "sandbox_id": row.get("sandbox_id"),
            "post_s": post,
            "wait_s": wait,
            "probe_s": probe,
            "post_pct_of_wall": share(post, wall_s),
            "wait_pct_of_wall": share(wait, wall_s),
            "probe_pct_of_wall": share(probe, wall_s),
        }

    record["last"] = client_rec(last)
    record["median"] = client_rec(median)
    for label, row in (("last", last), ("median", median)):
        sid = str(row.get("sandbox_id") or "")
        hit = by_vm.get(sid)
        if not hit:
            continue
        deliver, provisioning, load, toolbox, other, total = runner_bits(hit)
        record[label]["runner"] = {
            "queued_before_runner_ms": deliver,
            "provisioning_ms": provisioning,
            "memory_move_ms": load,
            "guest_ready_ms": toolbox,
            "other_ms": other,
            "total_ms": total,
        }
if serial_n:
    serial = {}
    for label, names in serial_buckets:
        ms = 0
        seen = False
        for name in names:
            if vals[name]:
                ms += pct(vals[name], 50)
                seen = True
        if not seen:
            continue
        sec = serial_n * ms / 1000.0
        serial[label] = {
            "p50_ms": ms,
            "serialized_s": sec,
            "pct_of_wall": share(sec, wall_s) if wall_s else None,
        }
    record["serial_share"] = serial
if jsonl_path and (wall_s or vals["total_ms"] or serial_n):
    with open(jsonl_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
    print(f"WALL_SHARE written to {jsonl_path}")
PY
  fi
  echo "END_EXIT=${status}"
  echo "OUTPUT=${OUTPUT}"
  if [[ -n "${OCI_VERA:-}" ]]; then
    echo "PUSH_THIS=git add ${OUTPUT}"
  fi
  exit "${status}"
} 2>&1 | tee "${LOG}"
status="${PIPESTATUS[0]}"
if [[ -d "$(dirname "${LOG_NVME}")" ]]; then
  cp -f "${LOG}" "${LOG_NVME}" 2>/dev/null || true
  echo "LOG_NVME=${LOG_NVME}" >>"${LOG}"
fi
exit "${status}"

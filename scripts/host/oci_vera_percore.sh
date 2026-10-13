#!/usr/bin/env bash
# Packed-throughput probe. Three agent runs, host counters during the work only.
#
#   L  44 sandboxes on one socket (spare cores)
#   P  352 sandboxes on that same socket (the published plateau)
#   H  176 sandboxes pinned to half of that socket
#
# OCI Vera has two sockets. The published Vera ladder is one socket, so "all
# cores" here is socket 0 (0-87,176-263), not all 352 threads. The sibling of
# cpu0 on this host is 0,176, so SIB is 176.
#
#   ./o probe
set -u

ROOT="${BENCH_DIR:-/home/ubuntu/arm64-benchmark-1}"
export HOME="${BENCH_HOME:-$(dirname "$ROOT")}"
cd "$ROOT" || exit 1
export PATH="/home/ubuntu/.local/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1 UV_NO_SYNC=1
export RLP_API_URL=http://127.0.0.1:8088
export RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
export REDSWITCHES_RLP_API_URL=http://127.0.0.1:8088
export REDSWITCHES_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
export VERA_RLP_API_URL=http://127.0.0.1:8088
export VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
export VERA_RLP_TARGET=vera
export RLP_HTTP_MAX_CONNECTIONS=8192
export RLP_HOLD_CREATE_BATCH=512
ulimit -n 1048576 || ulimit -n 65536 || true

TARGET="${TARGET:-vera}"
RLP_DISK="${RLP_DISK:-0.125}"
CPU_BASE="${CPU_BASE:-0}"
RUNS="${RUNS:-L P H}"
export REDSWITCHES_RLP_REGION="$TARGET"

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

if pgrep -f '/usr/local/bin/rlp-cpu-weight-floor' >/dev/null 2>&1; then
  echo "stop. the weight-floor loop is running." >&2
  exit 1
fi

nproc_now="$(nproc)"
sockets="$(lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')"
sib="$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)"
offset="${sib#*,}"
if [[ "${sib}" == "${offset}" || "${offset}" != "$(( nproc_now / 2 ))" ]]; then
  echo "sibling of cpu0 is ${sib}, nproc is ${nproc_now}. stop and send that line." >&2
  exit 1
fi

if [[ "${sockets}" == "2" ]]; then
  CORES="${CORES:-$(( nproc_now / 4 ))}"
  SIB="${SIB:-${offset}}"
  per="${CORES}"
  FULL_CPUS="${CPU_BASE}-$(( CPU_BASE + per - 1 )),$(( CPU_BASE + SIB ))-$(( CPU_BASE + SIB + per - 1 ))"
  SCOPE="socket 0, because this host has 2 sockets and the published ladder is one socket"
else
  CORES="${CORES:-$(( nproc_now / 2 ))}"
  SIB="${SIB:-${offset}}"
  FULL_CPUS="$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>/dev/null || echo "0-$(( nproc_now - 1 ))")"
  SCOPE="the only socket"
fi

HALF=$(( CORES / 2 ))
LIGHT=$(( CORES / 2 ))
HALF_CPUS="${CPU_BASE}-$(( CPU_BASE + HALF - 1 )),$(( CPU_BASE + SIB ))-$(( CPU_BASE + SIB + HALF - 1 ))"
ALL_CPUS="0-$(( nproc_now - 1 ))"
SLICE=/sys/fs/cgroup/rlp.slice

if [[ -d /mnt/data/bench-logs ]]; then
  OUT_BASE=/mnt/data/bench-logs
else
  OUT_BASE="${ROOT}/bench-logs"
fi
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="${PROBE_OUT:-${OUT_BASE}/percore-${TARGET}-${STAMP}}"
LOG="$OUT/probe.log"
say() { echo "$(date -u +%FT%T) $*" | tee -a "$LOG"; }

scratch="$(tr '\0' '\n' < /proc/"$(pgrep -nx rlp-api)"/environ 2>/dev/null | awk -F= '/^RLP_MIN_SCRATCH_MIB=/{print $2}' || true)"
if [[ -n "${scratch}" && "${scratch}" -gt 128 ]]; then
  echo "stop. RLP_MIN_SCRATCH_MIB=${scratch}, so a 128 MiB disk will be rounded up." >&2
  exit 1
fi

mkdir -p "$OUT_BASE"
perf_ok() {
  perf stat -a -e cycles,instructions -- sleep 1 >"$OUT_BASE/perf-check.txt" 2>&1
}

if ! perf_ok; then
  kernel="$(uname -r)"
  echo "perf cannot read cycles on ${kernel}. installing linux-tools-${kernel}."
  export DEBIAN_FRONTEND=noninteractive
  as_root apt-get update -qq || true
  if ! as_root apt-get install -y linux-tools-common "linux-tools-${kernel}"; then
    echo "linux-tools-${kernel} did not install. packages that match this kernel:" >&2
    apt-cache search linux-tools | grep -F "${kernel}" >&2 || apt-cache search linux-tools | grep -E '64k|generic' | head -20 >&2 || true
    echo "perf said:" >&2
    cat "$OUT_BASE/perf-check.txt" >&2 || true
    exit 1
  fi
  # A high paranoid value blocks system-wide perf even after the tools are installed.
  if [[ -w /proc/sys/kernel/perf_event_paranoid ]] || as_root test -w /proc/sys/kernel/perf_event_paranoid; then
    echo -1 | as_root tee /proc/sys/kernel/perf_event_paranoid >/dev/null || true
  fi
  if ! perf_ok; then
    echo "stop. perf still cannot read cycles after installing linux-tools-${kernel}." >&2
    cat "$OUT_BASE/perf-check.txt" >&2 || true
    exit 1
  fi
fi

if [[ -z "${OCI_PROBE_FOREGROUND:-}" ]]; then
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is missing. run: OCI_PROBE_FOREGROUND=1 ./o probe" >&2
    exit 1
  fi
  tmux start-server
  if tmux has-session -t probe 2>/dev/null; then
    echo "tmux session probe already exists. attach with: tmux attach -t probe" >&2
    exit 1
  fi
  tmux new-session -d -s probe \
    "cd '${ROOT}' && OCI_PROBE_FOREGROUND=1 bash scripts/host/oci_vera_percore.sh"
  echo "started tmux probe"
  echo "progress: tail -5 \$(ls -td ${OUT_BASE}/percore-${TARGET}-*/probe.log | head -1)"
  echo "wait for ALL DONE"
  exit 0
fi

mkdir -p "$OUT"

# A leftover CPUAffinity drop-in ignores the cpuset this probe writes.
for unit in rlp-runner rlp-api rlp-proxy; do
  dropin="/etc/systemd/system/${unit}.service.d/oci-gap.conf"
  if [[ -f "${dropin}" ]]; then
    as_root rm -f "${dropin}"
  fi
done
as_root systemctl daemon-reload >/dev/null 2>&1 || true

{
  echo "target=${TARGET} disk_gib=${RLP_DISK} arch=$(uname -m) cores=${CORES} sib=${SIB}"
  echo "scope=${SCOPE}"
  echo "light=${LIGHT} half_cpus=${HALF_CPUS} full_cpus=${FULL_CPUS}"
  lscpu | grep -E 'Model name|Socket|Core\(s\)|Thread|NUMA node' || true
  echo "kernel=$(uname -r) page=$(getconf PAGESIZE)"
  echo "runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) floor=0 scratch_mib=${scratch:-unread}"
  perf --version || true
} > "$OUT/host.txt" 2>&1
cat "$OUT/host.txt" | tee -a "$LOG"

metric_ok() { perf stat -a -M "$1" -- sleep 0.2 >/dev/null 2>&1; }
TD=""
for g in PipelineL1 TopdownL1 Topdown_L1 TopDownL1; do
  metric_ok "$g" && { TD=$g; break; }
done
TD2=""
for g in PipelineL2 TopdownL2 Topdown_L2 backend_memory_bound memory_bound; do
  metric_ok "$g" && { TD2=$g; break; }
done
BW=""
say "counters: base=cycles,instructions topdown=${TD:-none} topdown_l2=${TD2:-none} dram_bw=${BW:-none}"

same_cpus() {
  python3 - "$1" "$2" <<'PY'
import sys
def expand(text):
    out=set()
    for part in text.replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            a,b=part.split("-", 1)
            out.update(range(int(a), int(b)+1))
        else:
            out.add(int(part))
    return out
sys.exit(0 if expand(sys.argv[1])==expand(sys.argv[2]) else 1)
PY
}

# CPUAffinity is what stuck on this host. A cpuset write on the slice did not,
# and the 352-wide wave then ran on every core and died with no matching capacity.
apply_pin() {
  local cpus="$1" affinity runner_now vms_now conc
  affinity="${cpus//,/ }"
  as_root mkdir -p /etc/systemd/system/rlp-runner.service.d
  as_root tee /etc/systemd/system/rlp-runner.service.d/zz-probe.conf >/dev/null <<EOF
[Service]
CPUAffinity=${affinity}
AllowedMemoryNodes=0
Environment=RLP_VM_CONCURRENCY=512
Environment=RLP_VM_MAXACK=2048
Environment=RLP_MAX_LIVE_VMS=3000
EOF
  # The unit loads /etc/rlp/runner.env after drop-in Environment= lines, so the
  # file's 256 wins unless it is changed too. snapshots.conf repeats that 256.
  set_runner_kv RLP_VM_CONCURRENCY 512
  set_runner_kv RLP_VM_MAXACK 2048
  set_runner_kv RLP_MAX_LIVE_VMS 3000
  if [[ -f /etc/systemd/system/rlp-runner.service.d/snapshots.conf ]]; then
    as_root sed -i 's/^Environment=RLP_VM_CONCURRENCY=.*/Environment=RLP_VM_CONCURRENCY=512/' \
      /etc/systemd/system/rlp-runner.service.d/snapshots.conf
  fi
  as_root systemctl daemon-reload
  if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    echo +cpuset | as_root tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null
  fi
  if ! grep -qw cpuset "$SLICE/cgroup.subtree_control" 2>/dev/null; then
    echo +cpuset | as_root tee "$SLICE/cgroup.subtree_control" >/dev/null
  fi
  echo "$ALL_CPUS" | as_root tee "$SLICE/cpuset.cpus" >/dev/null
  echo "0-1" | as_root tee "$SLICE/cpuset.mems" >/dev/null
  if [[ ! -d "$SLICE/vms" ]]; then
    echo "missing ${SLICE}/vms. sandboxes would not be pinned." >&2
    exit 1
  fi
  if ! grep -qw cpuset "$SLICE/vms/cgroup.subtree_control" 2>/dev/null; then
    echo +cpuset | as_root tee "$SLICE/vms/cgroup.subtree_control" >/dev/null
  fi
  echo "$cpus" | as_root tee "$SLICE/vms/cpuset.cpus" >/dev/null
  echo "0" | as_root tee "$SLICE/vms/cpuset.mems" >/dev/null
  as_root systemctl restart rlp-runner
  sleep 15
  runner_now="$(awk '/Cpus_allowed_list/{print $2}' /proc/"$(pgrep -nx rlp-runner)"/status)"
  vms_now="$(tr -d '[:space:]' < "$SLICE/vms/cpuset.cpus.effective" 2>/dev/null || echo unread)"
  # /proc/<pid>/environ is root-only. A direct read prints "permission denied" and looks like a missing limit.
  conc="$(as_root cat /proc/"$(pgrep -nx rlp-runner)"/environ | tr '\0' '\n' | awk -F= '/^RLP_VM_CONCURRENCY=/{print $2}' | tail -1)"
  say "pin want=${cpus} runner=${runner_now} vms=${vms_now} vm_concurrency=${conc:-missing}"
  if ! same_cpus "${runner_now}" "${cpus}" || ! same_cpus "${vms_now}" "${cpus}"; then
    echo "pin did not stick. runner=${runner_now} vms=${vms_now} wanted=${cpus}" >&2
    exit 1
  fi
  if [[ "${conc}" != "512" ]]; then
    echo "runner concurrency is ${conc:-missing}, wanted 512. a 352-wide wave will be rejected." >&2
    exit 1
  fi
}

set_runner_kv() {
  local key="$1" value="$2" file=/etc/rlp/runner.env
  if [[ ! -f "${file}" ]]; then
    echo "${key}=${value}" | as_root tee "${file}" >/dev/null
    return
  fi
  if as_root grep -q "^${key}=" "${file}"; then
    as_root sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" | as_root tee -a "${file}" >/dev/null
  fi
}

restore_pin() {
  as_root rm -f /etc/systemd/system/rlp-runner.service.d/zz-probe.conf
  if [[ -f /etc/systemd/system/rlp-runner.service.d/snapshots.conf ]]; then
    as_root sed -i 's/^Environment=RLP_VM_CONCURRENCY=.*/Environment=RLP_VM_CONCURRENCY=256/' \
      /etc/systemd/system/rlp-runner.service.d/snapshots.conf || true
  fi
  set_runner_kv RLP_VM_CONCURRENCY 256 || true
  as_root systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ -d "$SLICE/vms" ]]; then
    echo "$ALL_CPUS" | as_root tee "$SLICE/vms/cpuset.cpus" >/dev/null || true
    echo "0-1" | as_root tee "$SLICE/vms/cpuset.mems" >/dev/null || true
  fi
  echo "$ALL_CPUS" | as_root tee "$SLICE/cpuset.cpus" >/dev/null || true
  as_root systemctl restart rlp-runner || true
  sleep 10
  say "pin restored runner=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status 2>/dev/null || echo unread)"
}
trap restore_pin EXIT

start_samplers() {
  local t="$1"
  : > "$OUT/$t.pids"
  perf stat -a -I 5000 -j -e cycles,instructions -o "$OUT/$t.ipc.json" &
  echo $! >> "$OUT/$t.pids"
  if [[ -n "$TD" ]]; then
    perf stat -a -I 5000 -j -M "$TD" -o "$OUT/$t.td.json" &
    echo $! >> "$OUT/$t.pids"
  fi
  if [[ -n "$TD2" ]]; then
    perf stat -a -I 5000 -j -M "$TD2" -o "$OUT/$t.td2.json" &
    echo $! >> "$OUT/$t.pids"
  fi
  (
    while true; do
      echo "$(date +%s.%N) $(pgrep -c firecracker || echo 0) $(awk '/^cpu /{print $2+$3+$4+$7+$8+$9, $5+$6}' /proc/stat)"
      sleep 5
    done
  ) > "$OUT/$t.host.txt" &
  echo $! >> "$OUT/$t.pids"
}

stop_samplers() {
  local pid
  if [[ -f "$OUT/$1.pids" ]]; then
    while read -r pid; do
      kill -INT "$pid" 2>/dev/null || true
    done < "$OUT/$1.pids"
    sleep 2
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$OUT/$1.pids"
  fi
}

psql_q() {
  # docker exec with no timeout will sit forever if Postgres is locked, and the probe prints nothing.
  if timeout 20 docker exec rlp-postgres true >/dev/null 2>&1; then
    timeout 30 docker exec rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null || true
  else
    as_root timeout 30 docker exec rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null || true
  fi
}

wait_clean() {
  local key id fc live i
  key="$(grep -E '^VERA_RLP_API_KEY=' .env | tail -1 | cut -d= -f2- || true)"
  if [[ -z "${key}" ]]; then
    key="$(grep -E '^RLP_API_KEY=' .env | tail -1 | cut -d= -f2- || true)"
  fi
  say "cleanup before the next wave"
  for i in $(seq 1 60); do
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      curl -s -o /dev/null -m 15 -X DELETE -H "Authorization: Bearer ${key}" \
        "http://127.0.0.1:8088/vms/${id}" || true
    done < <(psql_q "select id from vms where status not in ('deleted','failed','lost')")
    fc="$(pgrep -c firecracker || true)"
    live="$(psql_q "select count(*) from vms where status not in ('deleted','failed','lost')")"
    live="$(echo "${live}" | tr -d '[:space:]')"
    say "cleanup ${i} fc=${fc:-0} live=${live:-unread}"
    if [[ "${live:-unread}" == "0" && "${fc:-0}" != "0" ]]; then
      say "killing ${fc} firecracker processes the API no longer tracks"
      as_root pkill -9 firecracker || true
      sleep 2
      fc="$(pgrep -c firecracker || true)"
    fi
    if [[ "${fc:-0}" == "0" && "${live:-1}" == "0" ]]; then
      return 0
    fi
    sleep 5
  done
  say "WARN host not clean fc=${fc:-?} live=${live:-?}"
}

run_level() {
  local tag="$1" level="$2" cores="$3" rc
  wait_clean
  say "RUN ${tag} level=${level} cores_used=${cores} slice=$(cat $SLICE/cpuset.cpus.effective 2>/dev/null || echo unread) runner_cpus=$(awk '/Cpus_allowed_list/{print $2}' /proc/$(pgrep -nx rlp-runner)/status)"
  start_samplers "$tag"
  echo "${tag} ${level} ${cores} $(date +%s.%N)" >> "$OUT/runs.txt"
  set +e
  uv run main.py --benchmark agent --runner rlp --target "$TARGET" \
    --snapshot dtgraviet/vera-agent-benchmark:v3 --levels "$level" --n 45 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk "$RLP_DISK" \
    --output "$OUT/${tag}.jsonl" >> "$OUT/${tag}.harness.log" 2>&1
  rc=$?
  set -e
  echo "${tag} end $(date +%s.%N) rc=${rc}" >> "$OUT/runs.txt"
  stop_samplers "$tag"
  local fails
  fails="$(python3 - "$OUT/${tag}.jsonl" <<'PY'
import json, sys
fails = None
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if row.get("type") == "summary":
        fails = row.get("failures")
print("" if fails is None else fails)
PY
)"
  say "END ${tag} rc=${rc} failures=${fails:-unread}"
  if [[ "${rc}" != "0" || "${fails}" != "0" ]]; then
    echo "level ${tag} did not finish clean. rc=${rc} failures=${fails:-unread}" >&2
    exit 1
  fi
}

set -e
for r in $RUNS; do
  case "$r" in
    L) apply_pin "$FULL_CPUS"; run_level L "$LIGHT" "$CORES" ;;
    P) apply_pin "$FULL_CPUS"; run_level P 352 "$CORES" ;;
    H) apply_pin "$HALF_CPUS"; run_level H 176 "$HALF" ;;
    *) echo "unknown run ${r}" >&2; exit 2 ;;
  esac
done
restore_pin
trap - EXIT
say "ALL DONE -> ${OUT}"
python3 "${ROOT}/scripts/host/oci_vera_percore_summary.py" "$OUT" | tee "$OUT/summary.txt" || true
echo "send this directory: ${OUT}"

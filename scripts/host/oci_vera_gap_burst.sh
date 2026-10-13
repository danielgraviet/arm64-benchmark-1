#!/usr/bin/env bash
# One arm of the OCI Vera startup test. Called by oci_vera_gap.sh inside tmux.
# ARM is A-shared or B-split.
set -u
ARM="${1:?arm name}"
ROOT="${BENCH_DIR:-/home/ubuntu/arm64-benchmark-1}"
cd "${ROOT}" || { echo "set BENCH_DIR"; exit 1; }
export PATH="/home/ubuntu/.local/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1

if [[ -n "${LOGDIR:-}" && -d "${LOGDIR}" ]]; then
  :
elif [[ -d /mnt/data/bench-logs ]]; then
  LOGDIR=/mnt/data/bench-logs
else
  LOGDIR=/root/bench-logs
  mkdir -p "${LOGDIR}" 2>/dev/null || LOGDIR="${ROOT}/bench-logs"
  mkdir -p "${LOGDIR}"
fi

LOG="${LOGDIR}/vera-${ARM}-$(date -u +%Y%m%d_%H%M%S).log"
OUT=daniel-focus-here/oci-vera-jsonl
mkdir -p "${OUT}"

psql_q() {
  if docker exec rlp-postgres true >/dev/null 2>&1; then
    docker exec rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null
  else
    sudo -n docker exec rlp-postgres psql -U rlp -d rlplatform -tAc "$1" 2>/dev/null
  fi
}

KEY="$(grep -E '^VERA_RLP_API_KEY=' .env | tail -1 | cut -d= -f2- || true)"
if [[ -z "${KEY}" ]]; then
  KEY="$(grep -E '^RLP_API_KEY=' .env | tail -1 | cut -d= -f2- || true)"
fi

wait_clean() {
  local i id fc live
  for i in $(seq 1 240); do
    while IFS= read -r id; do
      [[ -n "${id}" ]] || continue
      curl -s -o /dev/null -m 30 -X DELETE -H "Authorization: Bearer ${KEY}" \
        "http://127.0.0.1:8088/vms/${id}" || true
    done < <(psql_q "select id from vms where status='running'")
    fc="$(pgrep -c firecracker || true)"
    live="$(psql_q "select count(*) from vms where status not in ('deleted','failed','lost')")"
    if [[ "${fc:-0}" == "0" && "${live:-0}" == "0" ]]; then
      return 0
    fi
    sleep 5
  done
  echo "WARN not clean fc=${fc:-?} live=${live:-?}" >> "${LOG}"
}

cpus_of() {
  local name="$1" pid
  pid="$(pgrep -nx "${name}" || true)"
  if [[ -z "${pid}" ]]; then
    echo missing
    return
  fi
  awk '/Cpus_allowed_list/{print $2}' "/proc/${pid}/status"
}

{
  echo "MARK start $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "$(date -u +%T) ARM=${ARM} rlp_slice=$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>/dev/null || echo unread) runner_cpus=$(cpus_of rlp-runner) api_cpus=$(cpus_of rlp-api) floor=$(pgrep -c -f '/bin/bash /usr/local/bin/rlp-cpu-weight-floor' || true) runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12)"
} >> "${LOG}"

echo "log ${LOG}"

wait_clean
TARGET=vera OCI_VERA=1 DISK_GB=0.015625 CREATE_READY_HTTP_POOL=1024 \
  bash scripts/host/run_create_ready.sh 10 >> "${LOG}.raw" 2>&1 || true

for spec in "1 1024 fast" "10 1024 fast" "100 1024 fast" "1000 1024 vera" "2000 4096 vera"; do
  set -- ${spec}
  N="$1"
  POOL="$2"
  if [[ "$3" == "fast" ]]; then
    PS=0.01
    PF=1
    PM=0.01
  else
    PS=0.25
    PF=1.5
    PM=2.0
  fi
  for rep in 1 2 3; do
    wait_clean
    sleep 1
    set +e
    RLP_WAIT_POLL_START_S="${PS}" RLP_WAIT_POLL_FACTOR="${PF}" RLP_WAIT_POLL_MAX_S="${PM}" \
      TARGET=vera OCI_VERA=1 DISK_GB=0.015625 CREATE_READY_HTTP_POOL="${POOL}" \
      bash scripts/host/run_create_ready.sh "${N}" >> "${LOG}.raw" 2>&1
    rc=$?
    set -e
    file="$(ls -t ${OUT}/vera_create_ready_${N}_*.jsonl 2>/dev/null | head -1 || true)"
    echo "FILE ${ARM} ${N} ${rep} rc=${rc} ${file}" >> "${LOG}"
    echo "FILE ${ARM} ${N} ${rep} rc=${rc} ${file}"
  done
done

echo "MARK end $(date -u '+%Y-%m-%d %H:%M:%S')" >> "${LOG}"
echo "$(date -u +%T) ALL DONE" >> "${LOG}"
echo "ALL DONE ${LOG}"

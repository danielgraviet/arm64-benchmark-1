#!/usr/bin/env bash
# OCI Vera startup test: does HQ's second socket explain the faster create?
#
# Arm A leaves both sockets shared. That is the 19 second setup.
# Arm B pins sandboxes and the runner to socket 0. The API, proxy, Postgres,
# NATS, and the benchmark client go to socket 1. This is the HQ pin.
# The earlier 41.6 second run pinned only the sandboxes. Do not repeat that.
#
#   ./o gap state
#   ./o gap A
#   ./o gap B
#   ./o gap sum
#   ./o gap undo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "${ROOT}"
export PATH="/home/ubuntu/.local/bin:${HOME}/.local/bin:/usr/local/bin:${PATH}"
export BENCH_DIR="${BENCH_DIR:-${ROOT}}"
export BENCH_HOME="${BENCH_HOME:-${HOME}}"

if [[ -d /mnt/data/bench-logs ]]; then
  LOGDIR=/mnt/data/bench-logs
else
  LOGDIR=/root/bench-logs
  mkdir -p "${LOGDIR}" 2>/dev/null || LOGDIR="${ROOT}/bench-logs"
  mkdir -p "${LOGDIR}"
fi

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

write_file() {
  local path="$1" value="$2"
  if [[ -w "${path}" ]]; then
    printf '%s\n' "${value}" > "${path}"
  else
    printf '%s\n' "${value}" | as_root tee "${path}" >/dev/null
  fi
}

stop_floor() {
  if pgrep -f '/usr/local/bin/rlp-cpu-weight-floor' >/dev/null 2>&1; then
    echo "stopping rlp-cpu-weight-floor"
    as_root pkill -f rlp-cpu-weight-floor.sh || true
    as_root systemctl disable --now rlp-cpu-weight-floor.service >/dev/null 2>&1 || true
    sleep 1
  fi
  local n
  n="$(pgrep -c -f '/bin/bash /usr/local/bin/rlp-cpu-weight-floor' || true)"
  if [[ "${n}" != "0" ]]; then
    echo "floor script still running (${n}). stop it before this test." >&2
    exit 1
  fi
}

socket_count() {
  lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}'
}

require_two_sockets() {
  local sockets
  sockets="$(socket_count)"
  if [[ "${sockets}" != "2" ]]; then
    echo "stop. socket count is ${sockets}. this test is the two-socket HQ split." >&2
    exit 1
  fi
}

# HQ layout: socket 0 is 0-87,176-263 and socket 1 is 88-175,264-351 on 352 threads.
# Sibling of cpu 0 must be half of nproc, which is that map.
load_socket_cpus() {
  local n sib offset per
  n="$(nproc)"
  sib="$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)"
  offset="${sib#*,}"
  if [[ "${sib}" == "${offset}" || "${offset}" != "$(( n / 2 ))" ]]; then
    echo "sibling of cpu0 is ${sib}, nproc is ${n}." >&2
    echo "expected siblings at N and N+$(( n / 2 )). send that line before arm B." >&2
    exit 1
  fi
  per=$(( n / 4 ))
  SOCKET0="0-$(( per - 1 )),${offset}-$(( offset + per - 1 ))"
  SOCKET1="${per}-$(( 2 * per - 1 )),$(( offset + per ))-$(( offset + 2 * per - 1 ))"
  ALL_CPUS="0-$(( n - 1 ))"
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

undo_pin() {
  local all slice vms unit dropin
  all="0-$(( $(nproc) - 1 ))"
  slice=/sys/fs/cgroup/rlp.slice
  vms="${slice}/vms"
  for unit in rlp-runner rlp-api rlp-proxy; do
    dropin="/etc/systemd/system/${unit}.service.d/oci-gap.conf"
    if [[ -f "${dropin}" ]]; then
      as_root rm -f "${dropin}"
    fi
  done
  as_root systemctl daemon-reload || true
  if [[ -f "${slice}/cpuset.cpus" ]]; then
    write_file "${slice}/cpuset.cpus" "${all}" || true
  fi
  if [[ -f "${slice}/cpuset.mems" ]]; then
    write_file "${slice}/cpuset.mems" "0-1" || true
  fi
  if [[ -f "${vms}/cpuset.cpus" ]]; then
    write_file "${vms}/cpuset.cpus" "${all}" || true
  fi
  if [[ -f "${vms}/cpuset.mems" ]]; then
    write_file "${vms}/cpuset.mems" "0-1" || true
  fi
  as_root docker update --cpuset-cpus="${all}" --cpuset-mems=0-1 rlp-postgres rlp-nats >/dev/null 2>&1 || true
  as_root systemctl restart rlp-runner rlp-api rlp-proxy || true
  sleep 15
  echo "pin removed. runner cpus: $(cpus_of rlp-runner)"
  echo "api cpus: $(cpus_of rlp-api)"
}

write_affinity() {
  local unit="$1" cpus="$2" mems="$3" dropin
  dropin="/etc/systemd/system/${unit}.service.d/oci-gap.conf"
  as_root mkdir -p "/etc/systemd/system/${unit}.service.d"
  # systemd wants spaces between ranges, not commas.
  as_root tee "${dropin}" >/dev/null <<EOF
[Service]
CPUAffinity=${cpus//,/ }
AllowedMemoryNodes=${mems}
EOF
}

apply_pin() {
  local slice vms runner_now api_now vms_now
  require_two_sockets
  load_socket_cpus
  slice=/sys/fs/cgroup/rlp.slice
  vms="${slice}/vms"
  echo "socket 0 (sandboxes and runner): ${SOCKET0}"
  echo "socket 1 (api, proxy, postgres, nats, client): ${SOCKET1}"
  if ! command -v taskset >/dev/null 2>&1; then
    echo "taskset is missing, so the client cannot be pinned to socket 1." >&2
    exit 1
  fi
  write_affinity rlp-runner "${SOCKET0}" 0
  write_affinity rlp-api "${SOCKET1}" 1
  if systemctl cat rlp-proxy >/dev/null 2>&1 || as_root systemctl cat rlp-proxy >/dev/null 2>&1; then
    write_affinity rlp-proxy "${SOCKET1}" 1
  fi
  as_root systemctl daemon-reload
  if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    write_file /sys/fs/cgroup/cgroup.subtree_control "+cpuset"
  fi
  if ! grep -qw cpuset "${slice}/cgroup.subtree_control" 2>/dev/null; then
    write_file "${slice}/cgroup.subtree_control" "+cpuset"
  fi
  # The slice stays on every core. Only the sandbox cgroup and the runner narrow.
  write_file "${slice}/cpuset.cpus" "${ALL_CPUS}"
  write_file "${slice}/cpuset.mems" "0-1"
  if [[ -d "${vms}" ]]; then
    if ! grep -qw cpuset "${vms}/cgroup.subtree_control" 2>/dev/null; then
      write_file "${vms}/cgroup.subtree_control" "+cpuset" || true
    fi
    write_file "${vms}/cpuset.cpus" "${SOCKET0}"
    write_file "${vms}/cpuset.mems" "0"
  fi
  as_root systemctl restart rlp-runner rlp-api rlp-proxy || as_root systemctl restart rlp-runner rlp-api
  as_root docker update --cpuset-cpus="${SOCKET1}" --cpuset-mems=1 rlp-postgres rlp-nats >/dev/null 2>&1 \
    || echo "postgres and nats cpuset was not changed"
  sleep 20
  runner_now="$(cpus_of rlp-runner)"
  api_now="$(cpus_of rlp-api)"
  vms_now="$(cat "${vms}/cpuset.cpus.effective" 2>/dev/null || echo unread)"
  echo "runner: ${runner_now}"
  echo "vms:    ${vms_now}"
  echo "api:    ${api_now}"
  if ! same_cpus "${runner_now}" "${SOCKET0}"; then
    echo "runner cpus are ${runner_now}, wanted ${SOCKET0}. undoing." >&2
    undo_pin
    exit 1
  fi
  if ! same_cpus "${vms_now}" "${SOCKET0}"; then
    echo "sandbox cpus are ${vms_now}, wanted ${SOCKET0}. undoing." >&2
    undo_pin
    exit 1
  fi
  if ! same_cpus "${api_now}" "${SOCKET1}"; then
    echo "api cpus are ${api_now}, wanted ${SOCKET1}. undoing." >&2
    undo_pin
    exit 1
  fi
  export GAP_CLIENT_CPUS="${SOCKET1}"
}

cmd_state() {
  stop_floor
  local out="${LOGDIR}/oci-vera-host-state.txt"
  {
    echo "== date: $(date -u)"
    echo "== host: $(hostname)"
    lscpu | grep -E 'Model name|Socket|Core\(s\)|Thread|NUMA node' || true
    echo "== sibling of cpu0: $(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)"
    echo "== nproc: $(nproc)"
    echo "== kernel: $(uname -r)  page size: $(getconf PAGESIZE)"
    echo "== cmdline: $(cat /proc/cmdline)"
    echo "== numa_balancing: $(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo unread)  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unread)"
    echo "== runner sha: $(sha256sum /usr/local/bin/rlp-runner | cut -c1-12)  mtime: $(stat -c %y /usr/local/bin/rlp-runner)"
    echo "== runner revision: $(go version -m /usr/local/bin/rlp-runner 2>/dev/null | grep vcs.revision || strings /usr/local/bin/rlp-runner | grep -m1 vcs.revision || echo none)"
    echo "== sudo-storm fix in runner: $(grep -a -c RLP_PRIV_EXEC_CONCURRENCY /usr/local/bin/rlp-runner || true)"
    echo "== quiet-progress patch in runner: $(grep -a -c RLP_QUIET_PROGRESS /usr/local/bin/rlp-runner || true)"
    echo "== api env:"
    tr '\0' '\n' < /proc/"$(pgrep -nx rlp-api)"/environ | grep -E 'RLP_(EVENT_AUDIT|MIN_|BURST)' || true
    echo "== runner env:"
    tr '\0' '\n' < /proc/"$(pgrep -nx rlp-runner)"/environ | grep -E 'RLP_(SNAPSHOTS|TEMPLATE|QUIET|VM_CONCURRENCY|NETNS_POOL|MAX_LIVE)' || true
    echo "== floor script running: 0"
    echo "== rlp.slice cpuset: $(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus.effective 2>/dev/null || echo unread)"
    echo "== disk:"
    df -h / /mnt/data 2>/dev/null || true
    echo "== memory:"
    free -g | sed -n 2p
  } | tee "${out}"
  echo "wrote ${out}"
  require_two_sockets
  load_socket_cpus
  echo "socket 0 would be ${SOCKET0}"
  echo "socket 1 would be ${SOCKET1}"
}

start_tmux() {
  local sub="$1" session="$2" arm="$3"
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is missing. run inside a long session:" >&2
    echo "  OCI_GAP_FOREGROUND=1 ./o gap ${sub}" >&2
    exit 1
  fi
  tmux start-server
  if tmux has-session -t "${session}" 2>/dev/null; then
    echo "tmux session ${session} already exists. attach with: tmux attach -t ${session}" >&2
    exit 1
  fi
  tmux new-session -d -s "${session}" \
    "cd '${ROOT}' && LOGDIR='${LOGDIR}' OCI_GAP_FOREGROUND=1 bash scripts/host/oci_vera_gap.sh ${sub}"
  echo "started tmux ${session}"
  echo "progress: tail -3 \$(ls -t ${LOGDIR}/vera-${arm}-*.log 2>/dev/null | grep -v raw | head -1)"
  echo "wait for ALL DONE, then: ./o gap sum"
}

cmd_shared() {
  stop_floor
  require_two_sockets
  if [[ -z "${OCI_GAP_FOREGROUND:-}" ]]; then
    start_tmux A armA A-shared
    return
  fi
  undo_pin
  export LOGDIR GAP_REPS=1
  unset GAP_CLIENT_CPUS
  bash "${SCRIPT_DIR}/oci_vera_gap_burst.sh" A-shared 1
}

cmd_split() {
  stop_floor
  require_two_sockets
  if [[ -z "${OCI_GAP_FOREGROUND:-}" ]]; then
    start_tmux B armB B-split
    return
  fi
  apply_pin
  trap undo_pin EXIT
  export LOGDIR GAP_REPS=3
  bash "${SCRIPT_DIR}/oci_vera_gap_burst.sh" B-split 3
}

cmd_sum() {
  BENCH_DIR="${BENCH_DIR}" LOGDIR="${LOGDIR}" python3 "${SCRIPT_DIR}/oci_vera_gap_summary.py" | tee /root/vera-summary.txt 2>/dev/null || \
    BENCH_DIR="${BENCH_DIR}" LOGDIR="${LOGDIR}" python3 "${SCRIPT_DIR}/oci_vera_gap_summary.py" | tee "${LOGDIR}/vera-summary.txt"
  local gap_out="${LOGDIR}/vera-gap.txt"
  : > "${gap_out}"
  local arm log start end
  for arm in A-shared B-split; do
    log="$(ls -t "${LOGDIR}/vera-${arm}-"*.log 2>/dev/null | grep -v raw | head -1 || true)"
    if [[ -z "${log}" ]]; then
      echo "== ${arm} no log" | tee -a "${gap_out}"
      continue
    fi
    start="$(awk '/^MARK start /{print $3, $4}' "${log}" | tail -1)"
    end="$(awk '/^MARK end /{print $3, $4}' "${log}" | tail -1)"
    echo "== ${arm} ${start} .. ${end}" | tee -a "${gap_out}"
    if [[ -n "${start}" && -n "${end}" ]]; then
      python3 "${SCRIPT_DIR}/oci_vera_gap.py" "${start}" "${end}" | tee -a "${gap_out}"
    fi
  done
  echo "summary and gap are in ${LOGDIR}"
}

usage() {
  cat <<EOF
./o gap state   record the host. needs 2 sockets. stops if the floor loop is up
./o gap A       one shared 1,000, both sockets, tmux session armA
./o gap B       three 1,000s with runner and sandboxes on socket 0
./o gap sum     print the table and the runner gap
./o gap undo    put every core back
logs: ${LOGDIR}
EOF
}

sub="${1:-}"
shift || true
case "${sub}" in
  state) cmd_state ;;
  A|a|shared) cmd_shared ;;
  B|b|split) cmd_split ;;
  undo) undo_pin ;;
  sum|summary) cmd_sum ;;
  h|help|-h|--help|"") usage ;;
  *)
    echo "unknown: ${sub}" >&2
    usage >&2
    exit 2
    ;;
esac

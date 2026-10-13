#!/usr/bin/env bash
# OCI Vera startup test: is the HQ gap the second socket?
#
# Arm A leaves every core shared. Arm B pins sandboxes and the runner to 75%
# of the cores and leaves 25% free for the API, Postgres, NATS, proxy, and client.
# One socket only. Two sockets is a different test.
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

# Prints the sandbox cpuset. Exits if this host is not a one-socket SMT Vera.
sandbox_cpus() {
  local sockets n sib offset phys keep
  sockets="$(socket_count)"
  n="$(nproc)"
  sib="$(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)"
  if [[ "${sockets}" != "1" ]]; then
    echo "this host has ${sockets} sockets. stop. the test is for one socket." >&2
    exit 1
  fi
  offset="${sib#*,}"
  if [[ "${sib}" == "${offset}" || "${offset}" != "$(( n / 2 ))" ]]; then
    echo "sibling of cpu0 is ${sib}, nproc is ${n}." >&2
    echo "expected siblings at N and N+$(( n / 2 )). send that line before arm B." >&2
    exit 1
  fi
  phys=$(( n / 2 ))
  keep=$(( phys * 3 / 4 ))
  if [[ "${keep}" -lt 1 || "${keep}" -ge "${phys}" ]]; then
    echo "could not take 75% of ${phys} cores" >&2
    exit 1
  fi
  printf '%s\n' "0-$(( keep - 1 )),${offset}-$(( offset + keep - 1 ))"
}

undo_pin() {
  local all slice vms
  all="0-$(( $(nproc) - 1 ))"
  slice=/sys/fs/cgroup/rlp.slice
  vms="${slice}/vms"
  if [[ -f "${slice}/cpuset.cpus" ]]; then
    write_file "${slice}/cpuset.cpus" "${all}"
  fi
  if [[ -f "${vms}/cpuset.cpus" ]]; then
    write_file "${vms}/cpuset.cpus" "${all}"
  fi
  echo "rlp.slice cpuset set back to ${all}"
  as_root systemctl restart rlp-runner
  sleep 15
  echo "rlp.slice back to: $(cat "${slice}/cpuset.cpus.effective" 2>/dev/null || echo unread)"
}

apply_pin() {
  local cpus slice vms
  cpus="$(sandbox_cpus)"
  slice=/sys/fs/cgroup/rlp.slice
  vms="${slice}/vms"
  echo "pinning sandboxes and runner to ${cpus}"
  echo "cores left free for the control plane: the rest of $(nproc) threads"
  if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
    write_file /sys/fs/cgroup/cgroup.subtree_control "+cpuset"
  fi
  if ! grep -qw cpuset "${slice}/cgroup.subtree_control" 2>/dev/null; then
    write_file "${slice}/cgroup.subtree_control" "+cpuset"
  fi
  write_file "${slice}/cpuset.cpus" "${cpus}"
  if [[ -d "${vms}" ]]; then
    if ! grep -qw cpuset "${vms}/cgroup.subtree_control" 2>/dev/null; then
      write_file "${vms}/cgroup.subtree_control" "+cpuset" || true
    fi
    write_file "${vms}/cpuset.cpus" "${cpus}" || true
  fi
  as_root systemctl restart rlp-runner
  sleep 20
  local slice_now runner_now api_now
  slice_now="$(cat "${slice}/cpuset.cpus.effective" 2>/dev/null || echo unread)"
  runner_now="$(awk '/Cpus_allowed_list/{print $2}' /proc/"$(pgrep -nx rlp-runner)"/status)"
  api_now="$(awk '/Cpus_allowed_list/{print $2}' /proc/"$(pgrep -nx rlp-api)"/status)"
  echo "rlp.slice: ${slice_now}"
  echo "runner:    ${runner_now}"
  echo "api:       ${api_now}"
  if [[ "${runner_now}" != "${cpus}" ]]; then
    echo "runner cpus are ${runner_now}, wanted ${cpus}. undoing." >&2
    undo_pin
    exit 1
  fi
  if [[ "${api_now}" == "${cpus}" ]]; then
    echo "api is pinned with the runner. undoing. the control plane must keep every core." >&2
    undo_pin
    exit 1
  fi
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
  local sockets
  sockets="$(socket_count)"
  if [[ "${sockets}" != "1" ]]; then
    echo "stop. socket count is ${sockets}, not 1." >&2
    exit 1
  fi
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
  if [[ "$(socket_count)" != "1" ]]; then
    echo "stop. socket count is $(socket_count), not 1." >&2
    exit 1
  fi
  if [[ -z "${OCI_GAP_FOREGROUND:-}" ]]; then
    start_tmux A armA A-shared
    return
  fi
  undo_pin
  export LOGDIR
  bash "${SCRIPT_DIR}/oci_vera_gap_burst.sh" A-shared
}

cmd_split() {
  stop_floor
  if [[ "$(socket_count)" != "1" ]]; then
    echo "stop. socket count is $(socket_count), not 1." >&2
    exit 1
  fi
  if [[ -z "${OCI_GAP_FOREGROUND:-}" ]]; then
    start_tmux B armB B-split
    return
  fi
  apply_pin
  trap undo_pin EXIT
  export LOGDIR
  bash "${SCRIPT_DIR}/oci_vera_gap_burst.sh" B-split
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
./o gap state   record the host. stops if the floor loop is up or sockets are not 1
./o gap A       shared cores. about 15-20 minutes in tmux session armA
./o gap B       pin 75% of cores to sandboxes and the runner, then the same runs
./o gap sum     print the table and the runner gap
./o gap undo    put rlp.slice back on every core
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

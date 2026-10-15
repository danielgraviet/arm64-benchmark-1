#!/usr/bin/env bash
# Detect / apply Zen5 cell profile for nvidia/o.
# Sourced by nvidia/o — do not exec.
#
# Profiles:
#   epyc9755  — single-socket 9755 bare cell (default)
#   phoenix-e6 — OCI dual-socket 9J45 with eng cell already live

_zen5_detect_region() {
  if [[ -n "${TARGET:-}" ]]; then
    printf '%s' "${TARGET}"
    return
  fi
  if [[ -n "${REGION_ID:-}" ]]; then
    printf '%s' "${REGION_ID}"
    return
  fi
  if [[ -r /etc/rlp/runner.env ]]; then
    local line
    line="$(grep -E '^RLP_RUNNER_REGION=' /etc/rlp/runner.env 2>/dev/null | tail -n1 || true)"
    if [[ -n "${line}" ]]; then
      printf '%s' "${line#*=}"
      return
    fi
  fi
  if sudo -n test -r /etc/rlp/runner.env 2>/dev/null; then
    local line
    line="$(sudo -n grep -E '^RLP_RUNNER_REGION=' /etc/rlp/runner.env 2>/dev/null | tail -n1 || true)"
    if [[ -n "${line}" ]]; then
      printf '%s' "${line#*=}"
      return
    fi
  fi
  printf 'epyc9755'
}

_zen5_apply_profile() {
  local region
  region="$(_zen5_detect_region)"
  case "${region}" in
    phoenix-e6)
      export TARGET=phoenix-e6
      export REGION_ID=phoenix-e6
      export CPU_TYPE_ID="${CPU_TYPE_ID:-turin-9j45}"
      export RUNNER_ID="${RUNNER_ID:-phoenix-e6-1}"
      export OUT_DIR="${OUT_DIR:-daniel-focus-here/zen5-9j45-jsonl}"
      export ZEN5_PROFILE=phoenix-e6
      # Eng cell is already live — never reseed as epyc9755.
      export SKIP_CELL="${SKIP_CELL:-1}"
      ;;
    *)
      export TARGET="${TARGET:-epyc9755}"
      export REGION_ID="${REGION_ID:-epyc9755}"
      export CPU_TYPE_ID="${CPU_TYPE_ID:-epyc9755}"
      export RUNNER_ID="${RUNNER_ID:-runner-epyc9755-1}"
      export OUT_DIR="${OUT_DIR:-daniel-focus-here/zen5-9755-jsonl}"
      export ZEN5_PROFILE=epyc9755
      ;;
  esac
}

_zen5_require_pin_if_9j45() {
  [[ "${ZEN5_PROFILE:-}" == "phoenix-e6" ]] || return 0
  local want_cpus want_mems cur_cpus cur_mems root
  root="${ROOT:-.}"
  want_cpus="$(tr -d '[:space:]' </sys/devices/system/node/node0/cpulist 2>/dev/null || true)"
  want_cpus="${want_cpus:-0-95,192-287}"
  want_mems="0"
  cur_cpus="$(tr -d '[:space:]' </sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null || true)"
  cur_mems="$(tr -d '[:space:]' </sys/fs/cgroup/rlp.slice/cpuset.mems 2>/dev/null || true)"
  if [[ -z "${cur_cpus}" ]]; then
    cur_cpus="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null | tr -d '[:space:]' || true)"
    cur_mems="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.mems 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ "${cur_cpus}" != "${want_cpus}" || "${cur_mems}" != "${want_mems}" ]]; then
    echo "[nvidia/o] pinning phoenix-e6 to socket 0 before timed run" >&2
    bash "${root}/tickets/9j45-pin-single-socket.sh" 0
  fi
}

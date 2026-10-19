#!/bin/bash
# Pin EPYC 9J45 (phoenix-e6) rlp.slice (+ VMs) to a single NUMA socket.
# Same model as tickets/vera-pin-single-socket.sh (whole slice on one socket).
#
# Topology on vedran-test / phoenix-e6 (2026-10-14):
#   node0 (socket 0): CPUs 0-95,192-287   mems 0
#   node1 (socket 1): CPUs 96-191,288-383 mems 1
#
# Usage:
#   bash tickets/9j45-pin-single-socket.sh          # pin node0
#   bash tickets/9j45-pin-single-socket.sh 1        # pin node1
#   bash tickets/9j45-pin-single-socket.sh undo     # restore all CPUs

set -euo pipefail

NODE="${1:-0}"
SLICE=/sys/fs/cgroup/rlp.slice
VMS="$SLICE/vms"

node_cpulist() {
  local n="$1"
  local path="/sys/devices/system/node/node${n}/cpulist"
  if [[ -r "${path}" ]]; then
    tr -d '[:space:]' <"${path}"
    return 0
  fi
  return 1
}

ALL_CPUS="$(
  python3 - <<'PY'
from pathlib import Path

def expand(text: str) -> set[int]:
    out: set[int] = set()
    for part in text.replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out

cpus: set[int] = set()
for p in sorted(Path("/sys/devices/system/node").glob("node*/cpulist")):
    cpus |= expand(p.read_text().strip())
if not cpus:
    print("0-383")
    raise SystemExit(0)
ordered = sorted(cpus)
ranges: list[str] = []
start = prev = ordered[0]
for c in ordered[1:]:
    if c == prev + 1:
        prev = c
        continue
    ranges.append(f"{start}-{prev}" if start != prev else str(start))
    start = prev = c
ranges.append(f"{start}-{prev}" if start != prev else str(start))
print(",".join(ranges))
PY
)"
ALL_MEMS="0-1"

if [[ "$NODE" == "undo" ]]; then
  echo "Restoring full CPU/mem set on rlp.slice…"
  sudo tee "$SLICE/cpuset.cpus" >/dev/null <<<"${ALL_CPUS:-0-383}"
  sudo tee "$SLICE/cpuset.mems" >/dev/null <<<"${ALL_MEMS}"
  if [[ -d "$VMS" ]]; then
    sudo tee "$VMS/cpuset.cpus" >/dev/null <<<"${ALL_CPUS:-0-383}" || true
    sudo tee "$VMS/cpuset.mems" >/dev/null <<<"${ALL_MEMS}" || true
  fi
  echo "Done. Restart runner if you want a clean adopt: sudo systemctl restart rlp-runner"
  exit 0
fi

if [[ "$NODE" == "0" ]]; then
  CPUS="$(node_cpulist 0 || true)"
  CPUS="${CPUS:-0-95,192-287}"
  MEMS="0"
elif [[ "$NODE" == "1" ]]; then
  CPUS="$(node_cpulist 1 || true)"
  CPUS="${CPUS:-96-191,288-383}"
  MEMS="1"
else
  echo "Usage: $0 [0|1|undo]" >&2
  exit 1
fi

echo "=== preflight ==="
systemctl is-active rlp-api rlp-proxy rlp-runner
curl -fsS http://127.0.0.1:8088/health
echo
if pgrep -af '[p]ython.*main.py.*--target (phoenix-e6|epyc9755|vera)' >/dev/null 2>&1; then
  echo "ERROR: benchmark still running. Stop it first." >&2
  exit 1
fi
if pgrep -af '[p]ython.*rlp_light_create_fleet' >/dev/null 2>&1; then
  echo "ERROR: create-ready fleet still running. Stop it first." >&2
  exit 1
fi
echo "no active harness"

# Writing cpuset.cpus blocks forever while Firecracker/runner threads sit on
# CPUs outside the new mask. Stop them before narrowing the slice.
echo "=== stop runner + drain Firecracker before cpuset write ==="
sudo systemctl stop rlp-runner || true
sleep 1
# pgrep -c prints 0 and exits 1 when idle — never use `|| echo 0` (that becomes 0\n0).
fc_left() {
  local n
  n="$(pgrep -c firecracker 2>/dev/null || true)"
  n="$(printf '%s' "${n:-0}" | tr -d '[:space:]')"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "${n}"
}
if [[ "$(fc_left)" != "0" ]]; then
  echo "pkill firecracker (would block cpuset.cpus otherwise)"
  sudo pkill -9 firecracker 2>/dev/null || true
  sleep 1
fi
fc_n="$(fc_left)"
echo "FC=${fc_n}"
if [[ "${fc_n}" != "0" ]]; then
  echo "ERROR: Firecracker still running; refuse to write cpuset" >&2
  sudo systemctl start rlp-runner || true
  exit 1
fi

echo "=== enable cpuset controller (root → rlp.slice → vms) ==="
if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
  sudo sh -c 'echo +cpuset > /sys/fs/cgroup/cgroup.subtree_control'
fi
if ! grep -qw cpuset "$SLICE/cgroup.subtree_control" 2>/dev/null; then
  sudo sh -c "echo +cpuset > $SLICE/cgroup.subtree_control"
fi

write_cpuset() {
  local path="$1" value="$2"
  # timeout: a stuck cpuset write is worse than a loud fail
  if ! printf '%s\n' "${value}" | sudo timeout 10 tee "${path}" >/dev/null; then
    echo "ERROR: timed out writing ${path}=${value}" >&2
    return 1
  fi
}

echo "=== pin rlp.slice to NUMA node$NODE (cpus=$CPUS mems=$MEMS) ==="
# mems first, then cpus (and children before parent when narrowing)
if [[ -d "$VMS" ]]; then
  if ! grep -qw cpuset "$VMS/cgroup.subtree_control" 2>/dev/null; then
    sudo sh -c "echo +cpuset > $VMS/cgroup.subtree_control" 2>/dev/null || true
  fi
  write_cpuset "$VMS/cpuset.mems" "$MEMS" || true
  write_cpuset "$VMS/cpuset.cpus" "$CPUS" || true
fi
write_cpuset "$SLICE/cpuset.mems" "$MEMS"
write_cpuset "$SLICE/cpuset.cpus" "$CPUS"

echo "=== start runner so new Firecracker procs inherit the pin ==="
sudo systemctl start rlp-runner
sleep 2
systemctl is-active rlp-runner
curl -fsS http://127.0.0.1:8088/health
echo

echo "=== verify ==="
# timeout: bare open of cpuset.cpus can hang the shell if something races the slice
read_cg() { sudo timeout 5 cat "$1" 2>/dev/null || echo unread; }
echo -n "rlp.slice cpus: "; read_cg "$SLICE/cpuset.cpus"
echo -n "rlp.slice mems: "; read_cg "$SLICE/cpuset.mems"
if [[ -d "$VMS" ]]; then
  echo -n "vms cpus: "; read_cg "$VMS/cpuset.cpus"
  echo -n "vms mems: "; read_cg "$VMS/cpuset.mems"
fi
RUNNER_PID=$(pgrep -nx rlp-runner || true)
if [[ -n "$RUNNER_PID" ]]; then
  echo -n "runner Cpus_allowed_list: "
  awk '/Cpus_allowed_list/ {print $2}' "/proc/$RUNNER_PID/status"
fi

echo
echo "Pinned to socket/NUMA node$NODE."
echo "Export for runners: SOCKET_PIN_CPUS=${CPUS} SOCKET_PIN_MEMS=${MEMS}"

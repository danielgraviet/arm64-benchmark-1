#!/bin/bash
# Pin Vera rlp.slice (+ VMs) to a single NUMA socket.
# Run on the Vera node as daytona (passwordless sudo).
#
# Topology on ipp8-d15-c2-vera-1 (2026-09-06):
#   node0 (socket 0): CPUs 0-87,176-263   mems 0
#   node1 (socket 1): CPUs 88-175,264-351 mems 1
#
# Usage:
#   bash tickets/vera-pin-single-socket.sh          # pin node0
#   bash tickets/vera-pin-single-socket.sh 1        # pin node1
#   bash tickets/vera-pin-single-socket.sh undo     # restore all CPUs

set -euo pipefail

NODE="${1:-0}"
SLICE=/sys/fs/cgroup/rlp.slice
VMS="$SLICE/vms"

if [[ "$NODE" == "undo" ]]; then
  echo "Restoring full CPU/mem set on rlp.slice…"
  sudo tee "$SLICE/cpuset.cpus" >/dev/null <<<"0-351"
  sudo tee "$SLICE/cpuset.mems" >/dev/null <<<"0-1"
  if [[ -d "$VMS" ]]; then
    sudo tee "$VMS/cpuset.cpus" >/dev/null <<<"0-351" || true
    sudo tee "$VMS/cpuset.mems" >/dev/null <<<"0-1" || true
  fi
  echo "Done. Restart runner if you want a clean adopt: sudo systemctl restart rlp-runner"
  exit 0
fi

if [[ "$NODE" == "0" ]]; then
  CPUS="0-87,176-263"
  MEMS="0"
elif [[ "$NODE" == "1" ]]; then
  CPUS="88-175,264-351"
  MEMS="1"
else
  echo "Usage: $0 [0|1|undo]" >&2
  exit 1
fi

echo "=== preflight ==="
systemctl is-active rlp-api rlp-proxy rlp-runner
curl -fsS http://127.0.0.1:8088/health
echo
pgrep -af '[p]ython.*main.py.*--target vera' && {
  echo "ERROR: benchmark still running. Stop it first." >&2
  exit 1
} || echo "no active vera harness"

echo "=== enable cpuset controller (root → rlp.slice → vms) ==="
# cgroup v2: parent must allow cpuset in subtree_control before children can use it
if ! grep -qw cpuset /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
  sudo sh -c 'echo +cpuset > /sys/fs/cgroup/cgroup.subtree_control'
fi
if ! grep -qw cpuset "$SLICE/cgroup.subtree_control" 2>/dev/null; then
  sudo sh -c "echo +cpuset > $SLICE/cgroup.subtree_control"
fi

echo "=== pin rlp.slice to NUMA node$NODE (cpus=$CPUS mems=$MEMS) ==="
sudo tee "$SLICE/cpuset.cpus" >/dev/null <<<"$CPUS"
sudo tee "$SLICE/cpuset.mems" >/dev/null <<<"$MEMS"
if [[ -d "$VMS" ]]; then
  if ! grep -qw cpuset "$VMS/cgroup.subtree_control" 2>/dev/null; then
    sudo sh -c "echo +cpuset > $VMS/cgroup.subtree_control" 2>/dev/null || true
  fi
  sudo tee "$VMS/cpuset.cpus" >/dev/null <<<"$CPUS" || true
  sudo tee "$VMS/cpuset.mems" >/dev/null <<<"$MEMS" || true
fi

echo "=== drain leftover sandboxes (best-effort) then restart runner ==="
# New Firecracker procs inherit the slice cpuset. Restart so runner + new VMs are clean.
sudo systemctl restart rlp-runner
sleep 2
systemctl is-active rlp-runner
curl -fsS http://127.0.0.1:8088/health
echo

echo "=== verify ==="
echo -n "rlp.slice cpus: "; cat "$SLICE/cpuset.cpus"
echo -n "rlp.slice mems: "; cat "$SLICE/cpuset.mems"
RUNNER_PID=$(pgrep -nx rlp-runner || true)
if [[ -n "$RUNNER_PID" ]]; then
  echo -n "runner Cpus_allowed_list: "
  awk '/Cpus_allowed_list/ {print $2}' "/proc/$RUNNER_PID/status"
fi

echo
echo "Pinned to socket/NUMA node$NODE."
echo "Capacity still advertises full host CPU count — keep ladder within one socket:"
echo "  ~88 physical cores → prefer levels ending at 352 or lower with --rlp-cpu 0.075"
echo "Calibrate --n for 1.8–2.0s at c=1, then run the ladder from /opt/bench with UV_NO_SYNC=1."

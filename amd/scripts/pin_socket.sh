#!/bin/bash
# Pin AMD EPYC 9996 rlp.slice (+ VMs) to a single NUMA node / socket half.
# Topology (vendor cell, 2026-10):
#   node0: 0-127,512-639   mems 0
#   node1: 128-255,640-767 mems 1
#   node2: 256-383,768-895 mems 2
#   node3: 384-511,896-1023 mems 3
# Two sockets × 256 cores; four NUMA nodes. Default pin = node0 (socket 0 side).
#
# Usage:
#   bash amd/scripts/pin_socket.sh          # pin node0
#   bash amd/scripts/pin_socket.sh 1        # pin node1
#   bash amd/scripts/pin_socket.sh undo     # restore all CPUs

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
    print("0-1023")
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
ALL_MEMS="0-3"

if [[ "$NODE" == "undo" ]]; then
  echo "Restoring full CPU/mem set on rlp.slice…"
  sudo tee "$SLICE/cpuset.cpus" >/dev/null <<<"${ALL_CPUS:-0-1023}"
  sudo tee "$SLICE/cpuset.mems" >/dev/null <<<"${ALL_MEMS}"
  if [[ -d "$VMS" ]]; then
    sudo tee "$VMS/cpuset.cpus" >/dev/null <<<"${ALL_CPUS:-0-1023}" || true
    sudo tee "$VMS/cpuset.mems" >/dev/null <<<"${ALL_MEMS}" || true
  fi
  echo "Done. Restart runner if you want a clean adopt: sudo systemctl restart rlp-runner"
  exit 0
fi

if [[ "$NODE" =~ ^[0-3]$ ]]; then
  CPUS="$(node_cpulist "${NODE}" || true)"
  case "${NODE}" in
    0) CPUS="${CPUS:-0-127,512-639}" ;;
    1) CPUS="${CPUS:-128-255,640-767}" ;;
    2) CPUS="${CPUS:-256-383,768-895}" ;;
    3) CPUS="${CPUS:-384-511,896-1023}" ;;
  esac
  MEMS="${NODE}"
else
  echo "Usage: $0 [0|1|2|3|undo]" >&2
  exit 1
fi

echo "=== preflight ==="
systemctl is-active rlp-api rlp-proxy rlp-runner
curl -fsS http://127.0.0.1:8088/health
echo
if pgrep -af '[p]ython.*main.py.*--target (epyc9996|epyc9755|phoenix-e6|vera)' >/dev/null 2>&1; then
  echo "ERROR: benchmark still running. Stop it first." >&2
  exit 1
fi
if pgrep -af '[p]ython.*rlp_light_create_fleet' >/dev/null 2>&1; then
  echo "ERROR: create-ready fleet still running. Stop it first." >&2
  exit 1
fi
echo "no active harness"

echo "=== stop runner + drain Firecracker before cpuset write ==="
sudo systemctl stop rlp-runner || true
sleep 1
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
  sleep 2
fi

echo "=== pin node${NODE}: cpus=${CPUS} mems=${MEMS} ==="
sudo mkdir -p "$SLICE" "$VMS" 2>/dev/null || true
# Ensure cpuset controller is available on the slice.
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  echo '+cpuset' | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null 2>&1 || true
fi
sudo tee "$SLICE/cpuset.cpus" >/dev/null <<<"${CPUS}"
sudo tee "$SLICE/cpuset.mems" >/dev/null <<<"${MEMS}"
if [[ -d "$VMS" ]]; then
  sudo tee "$VMS/cpuset.cpus" >/dev/null <<<"${CPUS}" || true
  sudo tee "$VMS/cpuset.mems" >/dev/null <<<"${MEMS}" || true
fi

echo "=== restart rlp-runner ==="
sudo systemctl start rlp-runner
sleep 3
systemctl is-active rlp-runner
echo "slice cpus=$(cat $SLICE/cpuset.cpus) mems=$(cat $SLICE/cpuset.mems)"
if [[ -d "$VMS" ]]; then
  echo "vms   cpus=$(cat $VMS/cpuset.cpus 2>/dev/null || echo n/a) mems=$(cat $VMS/cpuset.mems 2>/dev/null || echo n/a)"
fi
echo "pin ok (node ${NODE})"

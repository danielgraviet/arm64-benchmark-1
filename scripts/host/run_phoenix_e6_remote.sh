#!/usr/bin/env bash
# Agent driver: wait for SSH to phoenix-e6, sync harness, run full bench sequence.
# Usage (Mac): bash scripts/host/run_phoenix_e6_remote.sh
set -euo pipefail

HOST="${PHOENIX_E6_HOST:-158.101.39.4}"
USER="${PHOENIX_E6_USER:-ubuntu}"
ROOT_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -l "${USER}" "${HOST}")
RSYNC_SSH="ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15"

log() { printf '[phoenix-e6-remote %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

wait_ssh() {
  local i=0
  while true; do
    i=$((i + 1))
    if "${SSH[@]}" 'echo ok' >/dev/null 2>&1; then
      log "SSH ready (attempt ${i})"
      return 0
    fi
    log "SSH not ready (attempt ${i}); sleep 60"
    sleep 60
  done
}

sync_tree() {
  log "rsync harness (preserve remote .env)"
  "${SSH[@]}" 'test -f ~/arm64-benchmark-1/.env && cp -a ~/arm64-benchmark-1/.env /tmp/phoenix-e6.env || true'
  rsync -az --delete \
    --exclude '.venv/' \
    --exclude '.env' \
    --exclude '.env.*' \
    --exclude '__pycache__/' \
    --exclude '.DS_Store' \
    --exclude 'concurrency_*.jsonl' \
    --exclude 'vendor/' \
    -e "${RSYNC_SSH}" \
    "${ROOT_LOCAL}/" "${USER}@${HOST}:~/arm64-benchmark-1/"
  "${SSH[@]}" 'set -e
    if [[ -f /tmp/phoenix-e6.env ]]; then cp /tmp/phoenix-e6.env ~/arm64-benchmark-1/.env; chmod 600 ~/arm64-benchmark-1/.env; fi
    test -x ~/arm64-benchmark-1/phoenix-e6/o
  '
}

remote() {
  "${SSH[@]}" "$@"
}

wait_tmux() {
  local session="$1"
  local logpath="$2"
  local i=0
  while remote "tmux has-session -t ${session} 2>/dev/null"; do
    i=$((i + 1))
    if (( i % 6 == 0 )); then
      log "waiting for tmux ${session} (${i} min)…"
      remote "tail -3 ${logpath} 2>/dev/null || true" || true
    fi
    sleep 60
  done
  remote "grep -E 'END_EXIT=' ${logpath} | tail -1" || true
}

metrics_gate() {
  remote 'set -e
cd ~/arm64-benchmark-1
python3 - <<'"'"'PY'"'"'
import json, glob, sys
from pathlib import Path

want_cpus = Path("/sys/devices/system/node/node0/cpulist").read_text().strip()
slice_cpus = Path("/sys/fs/cgroup/rlp.slice/cpuset.cpus").read_text().strip()
slice_mems = Path("/sys/fs/cgroup/rlp.slice/cpuset.mems").read_text().strip()
assert slice_cpus == want_cpus and slice_mems == "0", (slice_cpus, slice_mems, want_cpus)

hw = sorted(glob.glob("daniel-focus-here/zen5-9j45-jsonl/host_hw_*.json"))
assert hw, "missing host_hw"
doc = json.loads(Path(hw[-1]).read_text())
assert doc.get("rlp_cell", {}).get("region_target") == "phoenix-e6"
assert doc.get("cpu", {}).get("numa_nodes")

creates = sorted(glob.glob("daniel-focus-here/zen5-9j45-jsonl/phoenix-e6_create_ready_*.jsonl"))
assert len(creates) >= 2, creates
dense = sorted(glob.glob("daniel-focus-here/zen5-9j45-jsonl/concurrency_*_n45.jsonl"))
assert dense, "missing dense jsonl"

def check_jsonl(path: str, *, need_wall: bool) -> None:
    meta = wall = False
    pin_ok = False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("type") == "meta":
                meta = True
                sp = obj.get("socket_pin") or {}
                if sp.get("slice_cpus") and sp.get("slice_mems"):
                    pin_ok = True
                if obj.get("socket_cpus") and obj.get("socket_mems"):
                    pin_ok = True
            if obj.get("type") == "wall_share" and obj.get("phase_p50_ms"):
                wall = True
            if obj.get("type") == "ladder":
                m = (obj.get("meta") or {})
                if (m.get("socket_pin") or {}).get("slice_cpus") or m.get("socket_cpus"):
                    pin_ok = True
    assert meta, f"no meta in {path}"
    assert pin_ok, f"socket_pin missing in {path}"
    if need_wall:
        assert wall, f"wall_share missing in {path}"

for p in creates[-2:]:
    check_jsonl(p, need_wall=True)
check_jsonl(dense[-1], need_wall=True)
print("METRICS_GATE_OK")
print("hw", hw[-1])
print("creates", creates[-2:])
print("dense", dense[-1])
PY
'
}

push_results() {
  remote 'set -e
cd ~/arm64-benchmark-1
git config user.email >/dev/null 2>&1 || git config user.email "ubuntu@phoenix-e6"
git config user.name >/dev/null 2>&1 || git config user.name "phoenix-e6 agent"
git add daniel-focus-here/zen5-9j45-jsonl/ data/agent/rlp-phoenix-e6-c0p025-max1/ phoenix-e6/results/ || true
if git diff --cached --quiet; then
  echo "nothing to commit on box; scp results instead"
  exit 3
fi
git commit -m "phoenix-e6 9J45: socket0 create+dense results"
git push origin HEAD || exit 4
'
}

main() {
  wait_ssh
  sync_tree
  log "start (harness only via phoenix-e6/o)"
  remote 'cd ~/arm64-benchmark-1/phoenix-e6 && ./o start'
  log "hw"
  remote 'cd ~/arm64-benchmark-1/phoenix-e6 && ./o hw'
  log "pin"
  remote 'cd ~/arm64-benchmark-1/phoenix-e6 && ./o pin'
  log "test"
  remote 'cd ~/arm64-benchmark-1/phoenix-e6 && ./o test'
  log "1k"
  remote 'cd ~/arm64-benchmark-1/phoenix-e6 && ./o clean && ./o 1k'
  wait_tmux zen5-1k /tmp/phoenix-e6-create-ready-1000.log
  log "2k"
  remote 'cd ~/arm64-benchmark-1/phoenix-e6 && ./o clean && ./o 2k'
  wait_tmux zen5-2k /tmp/phoenix-e6-create-ready-2000.log
  log "full-ladder"
  remote 'cd ~/arm64-benchmark-1/phoenix-e6 && ./o clean && ./o full-ladder'
  wait_tmux zen5-dense2k /tmp/zen5-9j45-dense2k-n45.log
  log "metrics gate"
  metrics_gate
  log "push results"
  if ! push_results; then
    log "git push on box failed; pulling results via rsync to Mac"
    mkdir -p "${ROOT_LOCAL}/daniel-focus-here/zen5-9j45-jsonl" \
      "${ROOT_LOCAL}/data/agent/rlp-phoenix-e6-c0p025-max1" \
      "${ROOT_LOCAL}/phoenix-e6/results"
    rsync -az -e "${RSYNC_SSH}" \
      "${USER}@${HOST}:~/arm64-benchmark-1/daniel-focus-here/zen5-9j45-jsonl/" \
      "${ROOT_LOCAL}/daniel-focus-here/zen5-9j45-jsonl/"
    rsync -az -e "${RSYNC_SSH}" \
      "${USER}@${HOST}:~/arm64-benchmark-1/data/agent/rlp-phoenix-e6-c0p025-max1/" \
      "${ROOT_LOCAL}/data/agent/rlp-phoenix-e6-c0p025-max1/"
    rsync -az -e "${RSYNC_SSH}" \
      "${USER}@${HOST}:~/arm64-benchmark-1/phoenix-e6/results/" \
      "${ROOT_LOCAL}/phoenix-e6/results/" || true
  fi
  log "DONE"
}

main "$@"

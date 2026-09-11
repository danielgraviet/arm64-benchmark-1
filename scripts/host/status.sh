#!/usr/bin/env bash
# Cell + harness snapshot for Codex or a human on the DUT.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

fc_count() {
  local n
  n="$(pgrep -c firecracker 2>/dev/null || true)"
  if [[ -z "${n}" ]]; then
    n=0
  fi
  printf '%s' "${n}"
}

echo "===HOST==="
hostname
date -u +"utc=%Y-%m-%dT%H:%M:%SZ"
whoami
echo "python=$(uv run python -c 'import sys; print(sys.version.split()[0])' 2>/dev/null || echo none)"
echo "ulimit_soft=$(ulimit -Sn) ulimit_hard=$(ulimit -Hn)"

echo "===TMUX==="
if tmux ls 2>/dev/null; then
  :
else
  echo none
fi

echo "===PROC==="
if pgrep -af 'main.py|rlp_light_create_fleet' 2>/dev/null | grep -v grep; then
  :
else
  echo noproc
fi

echo "===FC==="
echo "FC=$(fc_count)"

echo "===HEALTH==="
if curl -fsS -m 3 http://127.0.0.1:8088/health; then
  echo
else
  echo "health_fail"
fi

echo "===JSONL==="
ls -lt \
  data/agent/rlp-redswitches-*/concurrency_*.jsonl \
  results/zen5-jsonl/*.jsonl \
  2>/dev/null | head -n 12 || echo none

echo "===LOG_TAIL==="
for log in /tmp/zen5-dense2k-n45.log /tmp/zen5-create-ready-*.log; do
  if [[ -f "${log}" ]]; then
    echo "-- ${log} --"
    tail -n 8 "${log}"
  fi
done

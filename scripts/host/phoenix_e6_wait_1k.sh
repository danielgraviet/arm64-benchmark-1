#!/usr/bin/env bash
# Wait for vedran-test after OCI soft reset, then socket-0 pin + create-ready 1k.
set -euo pipefail

HOST="${PHOENIX_E6_HOST:-158.101.39.4}"
USER="${PHOENIX_E6_USER:-ubuntu}"
ROOT_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 -l "${USER}" "${HOST}")

log() { printf '[phoenix-e6-wait-1k %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

wait_healthy() {
  local i=0
  while true; do
    i=$((i + 1))
    if "${SSH[@]}" 'set -e
      echo ok
      # sudo must work; timeout avoids wedged D-state hangs
      timeout 5 sudo -n true
      systemctl is-active rlp-api rlp-proxy >/dev/null
      curl -fsS --max-time 5 http://127.0.0.1:8088/health >/dev/null
    ' >/dev/null 2>&1; then
      log "host healthy (attempt ${i})"
      return 0
    fi
    log "not healthy yet (attempt ${i}); sleep 30"
    sleep 30
  done
}

sync_fixes() {
  log "scp pin + o"
  scp -o BatchMode=yes -o ConnectTimeout=15 \
    "${ROOT_LOCAL}/tickets/9j45-pin-single-socket.sh" \
    "${USER}@${HOST}:~/arm64-benchmark-1/tickets/9j45-pin-single-socket.sh"
  scp -o BatchMode=yes -o ConnectTimeout=15 \
    "${ROOT_LOCAL}/phoenix-e6/o" \
    "${USER}@${HOST}:~/arm64-benchmark-1/phoenix-e6/o"
  "${SSH[@]}" 'chmod +x ~/arm64-benchmark-1/tickets/9j45-pin-single-socket.sh ~/arm64-benchmark-1/phoenix-e6/o'
}

run_1k() {
  log "pin + start 1k tmux"
  "${SSH[@]}" 'set -e
    cd ~/arm64-benchmark-1/phoenix-e6
    tmux has-session -t zen5-1k 2>/dev/null && tmux kill-session -t zen5-1k || true
    ./o pin
    ./o 1k
    tmux ls
  '
}

wait_healthy
sync_fixes
run_1k
log "1k tmux started — attach on box: tmux attach -t zen5-1k"

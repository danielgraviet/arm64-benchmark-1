#!/usr/bin/env bash
# Why a create was not picked up. Prints the live runner identity and the
# NATS subjects it bound. Restarts the runner once if the process is not
# advertising cpu_type=vera.
set -euo pipefail

log() { printf '[oci-why] %s\n' "$*"; }

read_environ() {
  local pid="$1"
  # The shell must not open /proc/PID/environ itself. That file is mode 400
  # and the redirect happens before sudo, which looks like "region empty".
  sudo -n cat "/proc/${pid}/environ" | tr '\0' '\n'
}

pin_runner_env() {
  sudo -n mkdir -p /etc/systemd/system/rlp-runner.service.d
  sudo -n tee /etc/systemd/system/rlp-runner.service.d/vera-cpu.conf >/dev/null <<'EOF'
[Service]
Environment=RLP_RUNNER_REGION=vera
Environment=RLP_RUNNER_CPU_TYPE=vera
EOF
  sudo -n systemctl daemon-reload
  sudo -n systemctl restart rlp-runner
}

pid="$(pgrep -nx rlp-runner || true)"
echo "=== runner process ==="
systemctl is-active rlp-runner 2>/dev/null || true
echo "pid=${pid:-none}"

live_region=""
live_cpu=""
if [[ -n "${pid}" ]]; then
  envdump="$(read_environ "${pid}" 2>/dev/null || true)"
  live_region="$(printf '%s\n' "${envdump}" | sed -n 's/^RLP_RUNNER_REGION=//p' | tail -n1)"
  live_cpu="$(printf '%s\n' "${envdump}" | sed -n 's/^RLP_RUNNER_CPU_TYPE=//p' | tail -n1)"
  printf '%s\n' "${envdump}" | grep -E '^(RLP_RUNNER_ID|RLP_RUNNER_REGION|RLP_RUNNER_CPU_TYPE|RLP_NATS_URL)=' || true
fi

echo "=== runner.env ==="
sudo -n grep -E '^(RLP_RUNNER_ID|RLP_RUNNER_REGION|RLP_RUNNER_CPU_TYPE|RLP_NATS_URL)=' /etc/rlp/runner.env 2>/dev/null || echo "(cannot read /etc/rlp/runner.env)"

if [[ "${live_cpu}" != "vera" || "${live_region}" != "vera" ]]; then
  log "live process region='${live_region:-empty}' cpu_type='${live_cpu:-empty}'"
  log "pinning Environment= on the systemd unit and restarting"
  pin_runner_env
  sleep 4
  pid="$(pgrep -nx rlp-runner || true)"
  if [[ -n "${pid}" ]]; then
    envdump="$(read_environ "${pid}" 2>/dev/null || true)"
    live_region="$(printf '%s\n' "${envdump}" | sed -n 's/^RLP_RUNNER_REGION=//p' | tail -n1)"
    live_cpu="$(printf '%s\n' "${envdump}" | sed -n 's/^RLP_RUNNER_CPU_TYPE=//p' | tail -n1)"
    echo "after restart pid=${pid} region=${live_region:-empty} cpu_type=${live_cpu:-empty}"
  fi
fi

echo "=== subjects this process bound ==="
# Only lines from the current boot (since the process start).
if [[ -n "${pid}" ]]; then
  start="$(ps -o lstart= -p "${pid}" 2>/dev/null || true)"
  if [[ -n "${start}" ]]; then
    sudo -n journalctl -u rlp-runner --since "${start}" --no-pager 2>/dev/null \
      | grep -E 'binding create|consumer bound|register' \
      | tail -n 20 || true
  fi
fi

echo "=== recent runner errors ==="
sudo -n journalctl -u rlp-runner -n 80 --no-pager -p warning 2>/dev/null | tail -n 15 || true

if [[ "${live_cpu}" == "vera" && "${live_region}" == "vera" ]]; then
  log "runner advertises vera. Creates with cpu_type=vera should be picked up."
  log "If smoke still says not picked up, the pool may still be warming (wait for ready=2100)."
else
  log "runner is NOT advertising vera. Creates for cpu_type=vera will sit for 60s."
fi

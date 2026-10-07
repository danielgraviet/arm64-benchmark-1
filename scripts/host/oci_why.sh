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

echo "=== runner row in postgres ==="
runner_rows="$(sudo -n docker exec rlp-postgres psql -U rlp -d rlplatform -tAc \
  "SELECT count(*) FROM runners;" 2>/dev/null || echo err)"
sudo -n docker exec rlp-postgres psql -U rlp -d rlplatform -c \
  "SELECT id, region_id, status, cpu_arch, cpu_type, last_seen_at FROM runners ORDER BY last_seen_at DESC NULLS LAST LIMIT 5;" \
  2>/dev/null || echo "(could not query runners table)"

echo "=== api register rejects ==="
sudo -n journalctl -u rlp-api --no-pager -n 400 2>/dev/null \
  | grep -E 'rejecting runner' | tail -n 15 || true

# A bare cell has no NVMe-oF target. The API refuses to insert the runner
# until RLP_ALLOW_NON_NVMEOF_RUNNERS=1. Binding NATS consumers is not enough:
# with zero rows, creates sit until the 60s cap.
if [[ "${runner_rows}" == "0" ]]; then
  log "runners table is empty. Allowing a non-NVMe-oF runner and re-registering."
  sudo -n mkdir -p /etc/systemd/system/rlp-api.service.d
  sudo -n tee /etc/systemd/system/rlp-api.service.d/no-nvmeof.conf >/dev/null <<'EOF'
[Service]
Environment=RLP_ALLOW_NON_NVMEOF_RUNNERS=1
EOF
  if ! sudo -n grep -q '^RLP_ALLOW_NON_NVMEOF_RUNNERS=1$' /etc/rlp/api.env 2>/dev/null; then
    echo 'RLP_ALLOW_NON_NVMEOF_RUNNERS=1' | sudo -n tee -a /etc/rlp/api.env >/dev/null
  fi
  sudo -n systemctl daemon-reload
  sudo -n systemctl restart rlp-api
  for _ in $(seq 1 30); do
    curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break
    sleep 1
  done
  sudo -n systemctl restart rlp-runner
  log "waiting 20s for the runner heartbeat (it registers every 10s)"
  sleep 20
  echo "=== api env flag ==="
  sudo -n systemctl show rlp-api -p Environment --no-pager 2>/dev/null | tr ' ' '\n' | grep -E 'NON_NVMEOF|RLP_ALLOW' || echo "(flag not visible on the unit)"
  echo "=== api warnings since restart ==="
  sudo -n journalctl -u rlp-api --since "3 min ago" --no-pager -p warning 2>/dev/null | tail -n 20 || true
  echo "=== runner row after re-register ==="
  sudo -n docker exec rlp-postgres psql -U rlp -d rlplatform -c \
    "SELECT id, region_id, status, cpu_arch, cpu_type FROM runners;" 2>/dev/null || true
  echo "=== regions and cpu_types ==="
  sudo -n docker exec rlp-postgres psql -U rlp -d rlplatform -c \
    "SELECT id, status FROM regions; SELECT id, cpu_arch, tier FROM cpu_types WHERE id='vera';" 2>/dev/null || true
fi

echo "=== subjects this process bound ==="
echo "expect jobs.vm.create.vera.vera (and jobs.vm.create.vera.arm64)"
sudo -n journalctl -u rlp-runner --no-pager -n 2000 2>/dev/null \
  | grep -E 'consumer bound|binding create selector|register' \
  | tail -n 25 || true

echo "=== recent runner errors ==="
sudo -n journalctl -u rlp-runner -n 80 --no-pager -p warning 2>/dev/null | tail -n 15 || true

if [[ "${live_cpu}" == "vera" && "${live_region}" == "vera" ]]; then
  log "runner advertises vera. Creates with cpu_type=vera should be picked up."
  log "If smoke still says not picked up, the pool may still be warming (wait for ready=2100)."
else
  log "runner is NOT advertising vera. Creates for cpu_type=vera will sit for 60s."
fi

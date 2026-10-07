#!/usr/bin/env bash
# Register cpu_type=vera (arm64) and point the runner at it.
# Smoke/harness sends cpu_type=vera; a fresh cell 400s until the row exists.
set -euo pipefail

log() { printf '[oci-cpu] %s\n' "$*"; }

run_docker() {
  if docker info >/dev/null 2>&1; then docker "$@"
  else sudo -n docker "$@"
  fi
}

run_docker exec -i rlp-postgres psql -U rlp -d rlplatform -v ON_ERROR_STOP=1 -q <<'SQL'
INSERT INTO cpu_types (id, name, cpu_arch, tier)
VALUES ('vera', 'NVIDIA Vera', 'arm64', 1)
ON CONFLICT (id) DO UPDATE
  SET name=EXCLUDED.name, cpu_arch=EXCLUDED.cpu_arch, tier=EXCLUDED.tier;
SQL

if ! sudo -n grep -q '^RLP_RUNNER_CPU_TYPE=vera$' /etc/rlp/runner.env; then
  echo 'RLP_RUNNER_CPU_TYPE=vera' | sudo -n tee -a /etc/rlp/runner.env >/dev/null
  log "set RLP_RUNNER_CPU_TYPE=vera; restarting runner"
  sudo -n systemctl restart rlp-runner
  sleep 2
else
  log "runner already advertises cpu_type=vera"
fi
log "cpu_type vera ready"

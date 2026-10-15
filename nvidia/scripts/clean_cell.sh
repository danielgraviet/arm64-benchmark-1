#!/usr/bin/env bash
# Drain all sandboxes on the Zen5 cell, then ensure no Firecracker orphans.
# Prefer API DELETE. Only pkill firecracker when API reports live=0 but FC>0.
#
# Usage:  cd nvidia && ./o clean
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIDIA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${NVIDIA_DIR}/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/profile.sh"
_zen5_apply_profile

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1
export PYTHONUNBUFFERED=1

TARGET="${TARGET:-epyc9755}"
WAIT_SECS="${CLEAN_WAIT_SECS:-60}"
POLL_SECS="${CLEAN_POLL_SECS:-2}"

log() { printf '[clean] %s\n' "$*"; }
die() { printf '[clean] ERROR: %s\n' "$*" >&2; exit 1; }

fc_count() {
  pgrep -c firecracker 2>/dev/null || echo 0
}

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

# Always pin localhost after sourcing .env.
export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_API_URL="http://127.0.0.1:8088"
export REDSWITCHES_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export REDSWITCHES_RLP_REGION="${TARGET}"

if ! curl -fsS -m 5 http://127.0.0.1:8088/health >/dev/null 2>&1; then
  die "API health failed on :8088 — is the cell up? (./o start / ./o status)"
fi

log "paginated API drain --target ${TARGET}"
UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}"

# Wait for API live=0 (cleanup script already deletes; re-check via /vms briefly).
deadline=$((SECONDS + WAIT_SECS))
live=-1
while (( SECONDS < deadline )); do
  live="$(
    UV_NO_SYNC=1 TARGET="${TARGET}" uv run python - <<'PY' 2>/dev/null || echo -1
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path.cwd()))
from dotenv import load_dotenv
load_dotenv(override=True)
from harness.regions import resolve_rlp_client_config
from rlp import Daytona
from urllib.parse import quote

cfg = resolve_rlp_client_config(os.environ.get("TARGET", "epyc9755"))
d = Daytona(cfg)
api = d._api
live = 0
cursor = None
while True:
    path = "/vms" if not cursor else f"/vms?cursor={quote(cursor, safe='')}"
    data = api.get(path).json()
    for vm in data.get("vms", []):
        if (vm.get("status") or "").lower() != "deleted":
            live += 1
    cursor = data.get("next_cursor")
    if not cursor:
        break
print(live)
PY
  )"
  live="$(echo "${live:-}" | tr -d '[:space:]')"
  [[ -n "${live}" ]] || live="-1"
  fc="$(fc_count)"
  log "live=${live} FC=${fc}"
  if [[ "${live}" == "0" ]]; then
    break
  fi
  sleep "${POLL_SECS}"
done

if [[ "${live}" != "0" ]]; then
  die "API still reports live=${live} after ${WAIT_SECS}s"
fi

fc="$(fc_count)"
if [[ "${fc}" != "0" ]]; then
  log "API live=0 but FC=${fc} — orphan pkill after short settle"
  sleep 3
  fc="$(fc_count)"
  if [[ "${fc}" != "0" ]]; then
    log "pkill -9 firecracker (orphans)"
    sudo -n pkill -9 firecracker 2>/dev/null || pkill -9 firecracker 2>/dev/null || true
    sleep 2
  fi
fi

fc="$(fc_count)"
live_final="${live}"
log "done live=${live_final} FC=${fc}"
if [[ "${fc}" != "0" ]]; then
  die "FC=${fc} after drain — refuse to continue with orphans"
fi
exit 0

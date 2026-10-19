#!/usr/bin/env bash
# Drain all sandboxes on phoenix-e6, then ensure no Firecracker orphans.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHOENIX_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${PHOENIX_DIR}/.." && pwd)"
cd "${ROOT}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC=1
export PYTHONUNBUFFERED=1
TARGET=phoenix-e6
WAIT_SECS="${CLEAN_WAIT_SECS:-60}"
POLL_SECS="${CLEAN_POLL_SECS:-2}"

log() { printf '[clean] %s\n' "$*"; }
die() { printf '[clean] ERROR: %s\n' "$*" >&2; exit 1; }

# pgrep -c prints 0 and exits 1 when idle; never append another "0" via || echo.
fc_count() {
  local n
  n="$(pgrep -c firecracker 2>/dev/null || true)"
  n="$(echo "${n:-0}" | tr -d '[:space:]')"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "${n}"
}

# Count non-deleted VMs via raw HTTP (no uv/sdk — those probes were returning -1).
live_count() {
  python3 - <<'PY'
import json, urllib.parse, urllib.request
from pathlib import Path

key = ""
env = Path(".env")
if env.exists():
    for line in env.read_text().splitlines():
        if line.startswith("RLP_API_KEY="):
            key = line.split("=", 1)[1].strip().strip("'\"")
            break
if not key:
    raise SystemExit("missing RLP_API_KEY")

base = "http://127.0.0.1:8088"

def get(path: str):
    req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)

live = 0
cursor = None
while True:
    path = "/vms" if not cursor else f"/vms?cursor={urllib.parse.quote(cursor, safe='')}"
    data = get(path)
    for vm in data.get("vms", []):
        if (vm.get("status") or "").lower() != "deleted":
            live += 1
    cursor = data.get("next_cursor")
    if not cursor:
        break
print(live)
PY
}

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"

curl -fsS -m 5 http://127.0.0.1:8088/health >/dev/null \
  || die "API health failed on :8088"

log "paginated API drain --target ${TARGET}"
UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target "${TARGET}"

deadline=$((SECONDS + WAIT_SECS))
live=-1
while (( SECONDS < deadline )); do
  if ! live="$(live_count 2>/dev/null)"; then
    live="-1"
  fi
  live="$(echo "${live:-}" | tr -d '[:space:]')"
  [[ -n "${live}" ]] || live="-1"
  fc="$(fc_count)"
  log "live=${live} FC=${fc}"
  [[ "${live}" == "0" ]] && break
  sleep "${POLL_SECS}"
done

[[ "${live}" == "0" ]] || die "API still reports live=${live} after ${WAIT_SECS}s"

fc="$(fc_count)"
if [[ "${fc}" != "0" ]]; then
  log "API live=0 but FC=${fc} — orphan pkill after short settle"
  sleep 3
  fc="$(fc_count)"
  if [[ "${fc}" != "0" ]]; then
    sudo -n pkill -9 firecracker 2>/dev/null || pkill -9 firecracker 2>/dev/null || true
    sleep 2
  fi
fi

fc="$(fc_count)"
log "done live=0 FC=${fc}"
[[ "${fc}" == "0" ]] || die "FC=${fc} after drain — refuse to continue with orphans"
exit 0

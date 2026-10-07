#!/usr/bin/env bash
# Pass/fail audit for OCI / onsite Vera create-ready + dense parity knobs.
# Run on the DUT after cell install. Exit 0 only if all required checks pass.
#
# Usage:
#   bash scripts/host/check_vera_parity.sh
#   bash scripts/host/check_vera_parity.sh --strict   # also fail on optional warns
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
fi

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC="${UV_NO_SYNC:-1}"

PASS=0
FAIL=0
WARN=0

ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf 'WARN  %s\n' "$*"; WARN=$((WARN + 1)); }

# /etc/rlp/*.env is mode 600 root. Read via sudo into temp copies.
TMPDIR_PARITY="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_PARITY}"' EXIT
read_root_env() {
  local src="$1" dest="$2"
  if sudo -n test -f "${src}" 2>/dev/null || [[ -r "${src}" ]]; then
    if [[ -r "${src}" ]]; then
      cp "${src}" "${dest}"
    else
      sudo -n cat "${src}" > "${dest}" 2>/dev/null || true
    fi
  fi
  [[ -s "${dest}" ]]
}
read_root_env /etc/rlp/api.env "${TMPDIR_PARITY}/api.env" || true
read_root_env /etc/rlp/runner.env "${TMPDIR_PARITY}/runner.env" || true

env_file_has() {
  local file="$1" key="$2" want="$3"
  [[ -f "${file}" ]] || return 1
  local line
  line="$(grep -E "^${key}=" "${file}" | tail -n1 || true)"
  [[ -n "${line}" ]] || return 1
  local val="${line#*=}"
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"
  [[ "${val}" == "${want}" ]]
}

env_file_int_ge() {
  local file="$1" key="$2" min="$3"
  [[ -f "${file}" ]] || return 1
  local line val
  line="$(grep -E "^${key}=" "${file}" | tail -n1 || true)"
  [[ -n "${line}" ]] || return 1
  val="${line#*=}"
  val="${val%\"}"
  val="${val#\"}"
  [[ "${val}" =~ ^[0-9]+$ ]] || return 1
  (( val >= min ))
}

echo "=== Vera parity check (cwd=${ROOT}) ==="

# --- API health ---
if curl -fsS -m 5 http://127.0.0.1:8088/health >/dev/null 2>&1; then
  ok "API health http://127.0.0.1:8088/health"
else
  bad "API health (curl :8088/health failed)"
fi

# Toolbox: any HTTP response (even 401/404) means the port is up.
tb_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/toolbox 2>/dev/null || echo 000)"
if [[ "${tb_code}" != "000" ]]; then
  ok "toolbox listens on :9000 (http ${tb_code})"
else
  bad "toolbox not reachable on http://127.0.0.1:9000/toolbox"
fi

# --- systemd ---
for unit in rlp-api rlp-proxy rlp-runner; do
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    ok "systemctl ${unit} active"
  else
    bad "systemctl ${unit} not active"
  fi
done

# --- Firecracker ---
if command -v firecracker >/dev/null 2>&1; then
  fc_ver="$(firecracker --version 2>&1 | head -n1 || true)"
  if echo "${fc_ver}" | grep -q '1\.16\.1'; then
    ok "firecracker ${fc_ver}"
  else
    warn "firecracker version not 1.16.1 (${fc_ver:-missing})"
  fi
else
  bad "firecracker not on PATH"
fi

# --- Cell env: api ---
API_ENV="${TMPDIR_PARITY}/api.env"
if env_file_has "${API_ENV}" RLP_BURST_MAX_CPU 1; then
  ok "api.env RLP_BURST_MAX_CPU=1"
else
  bad "api.env RLP_BURST_MAX_CPU must be 1 (create-ready omits client cpu_max)"
fi

# Mins must allow 0.025 cpu / ~64 MiB.
if [[ -f "${API_ENV}" ]]; then
  min_cpu_line="$(grep -E '^RLP_MIN_CPU=' "${API_ENV}" | tail -n1 || true)"
  if [[ -z "${min_cpu_line}" ]]; then
    warn "api.env RLP_MIN_CPU unset (defaults may clamp 0.025 upward)"
  else
    min_cpu="${min_cpu_line#*=}"
    # awk compare floats
    if awk -v v="${min_cpu}" 'BEGIN { exit !(v+0 <= 0.025) }'; then
      ok "api.env RLP_MIN_CPU=${min_cpu} <= 0.025"
    else
      bad "api.env RLP_MIN_CPU=${min_cpu} > 0.025"
    fi
  fi
  min_mem_line="$(grep -E '^RLP_MIN_MEM_MIB=' "${API_ENV}" | tail -n1 || true)"
  if [[ -z "${min_mem_line}" ]]; then
    warn "api.env RLP_MIN_MEM_MIB unset (defaults may clamp 64 MiB upward)"
  else
    min_mem="${min_mem_line#*=}"
    if [[ "${min_mem}" =~ ^[0-9]+$ ]] && (( min_mem <= 64 )); then
      ok "api.env RLP_MIN_MEM_MIB=${min_mem} <= 64"
    else
      bad "api.env RLP_MIN_MEM_MIB=${min_mem} must be <= 64"
    fi
  fi
else
  bad "cannot read /etc/rlp/api.env (sudo?)"
fi

# --- Cell env: runner ---
RUN_ENV="${TMPDIR_PARITY}/runner.env"
if env_file_has "${RUN_ENV}" RLP_SNAPSHOTS 1; then
  ok "runner.env RLP_SNAPSHOTS=1"
else
  bad "runner.env RLP_SNAPSHOTS must be 1"
fi

if env_file_int_ge "${RUN_ENV}" RLP_VM_CONCURRENCY 128; then
  ok "runner.env RLP_VM_CONCURRENCY >= 128"
else
  bad "runner.env RLP_VM_CONCURRENCY must be >= 128 (1k pickup wall)"
fi

if env_file_int_ge "${RUN_ENV}" RLP_MAX_LIVE_VMS 2500; then
  ok "runner.env RLP_MAX_LIVE_VMS >= 2500"
else
  bad "runner.env RLP_MAX_LIVE_VMS must be >= 2500 for create-ready 2k"
fi

if env_file_int_ge "${RUN_ENV}" RLP_NETNS_POOL 2100; then
  ok "runner.env RLP_NETNS_POOL >= 2100"
else
  bad "runner.env RLP_NETNS_POOL must be >= 2100"
fi

if [[ -f "${RUN_ENV}" ]] && grep -qE '^RLP_RUNNER_REGION=vera$' "${RUN_ENV}"; then
  ok "runner.env RLP_RUNNER_REGION=vera"
else
  bad "runner.env RLP_RUNNER_REGION must be vera"
fi

if [[ -f "${RUN_ENV}" ]]; then
  for key in RLP_KERNEL RLP_INITDISK; do
    if grep -qE "^${key}=" "${RUN_ENV}"; then
      path="$(grep -E "^${key}=" "${RUN_ENV}" | tail -n1 | cut -d= -f2-)"
      path="${path%\"}"
      path="${path#\"}"
      if [[ -f "${path}" ]]; then
        ok "${key}=${path} exists"
      else
        bad "${key}=${path} missing on disk"
      fi
    else
      bad "runner.env missing ${key}"
    fi
  done
fi

# --- Host neigh sysctl ---
thresh3="$(sysctl -n net.ipv4.neigh.default.gc_thresh3 2>/dev/null || echo 0)"
if [[ "${thresh3}" =~ ^[0-9]+$ ]] && (( thresh3 >= 16384 )); then
  ok "neigh gc_thresh3=${thresh3} (>= 16384)"
else
  bad "neigh gc_thresh3=${thresh3} too low (raise like tune_epyc9575_create.sh)"
fi

# --- Client .env ---
if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

for var in VERA_RLP_API_URL VERA_RLP_TOOLBOX_URL VERA_RLP_API_KEY VERA_RLP_TARGET; do
  val="${!var:-}"
  if [[ -z "${val}" ]]; then
    bad ".env missing ${var}"
  else
    ok ".env ${var} set"
  fi
done

if [[ "${VERA_RLP_API_URL:-}" == "http://127.0.0.1:8088" ]]; then
  ok "VERA_RLP_API_URL is localhost :8088"
else
  bad "VERA_RLP_API_URL must be http://127.0.0.1:8088 (got ${VERA_RLP_API_URL:-empty})"
fi

if [[ "${VERA_RLP_TOOLBOX_URL:-}" == "http://127.0.0.1:9000/toolbox" ]]; then
  ok "VERA_RLP_TOOLBOX_URL is localhost toolbox"
else
  bad "VERA_RLP_TOOLBOX_URL must be http://127.0.0.1:9000/toolbox"
fi

if [[ "${VERA_RLP_TARGET:-}" == "vera" ]]; then
  ok "VERA_RLP_TARGET=vera"
else
  bad "VERA_RLP_TARGET must be vera"
fi

# --- Eng SDK ---
if UV_NO_SYNC=1 uv run python -c '
from rlp import DaytonaConfig, Resources
assert "region_routing" in DaytonaConfig.__dataclass_fields__
assert "cpu_max" in Resources.__dataclass_fields__
assert "memory_max" in Resources.__dataclass_fields__
print("ok")
' >/dev/null 2>&1; then
  ok "eng rlp-sdk has region_routing + cpu_max + memory_max"
else
  bad "eng rlp-sdk missing fields (run scripts/host/install_eng_rlp_sdk.sh)"
fi

# --- Optional: socket pin / region row ---
if [[ -d /sys/fs/cgroup/rlp.slice ]]; then
  cpus="$(cat /sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null || true)"
  if [[ "${cpus}" == "0-87,176-263" ]]; then
    ok "rlp.slice cpuset pinned to socket0 (${cpus})"
  elif [[ -n "${cpus}" ]]; then
    warn "rlp.slice cpuset=${cpus} (onsite create-ready used 0-87,176-263)"
  else
    warn "rlp.slice present but cpuset unreadable"
  fi
else
  warn "rlp.slice missing (pin after runner is up: tickets/vera-pin-single-socket.sh)"
fi

# Region row in Postgres (best-effort).
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx rlp-postgres; then
  if docker exec rlp-postgres psql -U rlp -d rlplatform -tAc \
    "SELECT 1 FROM regions WHERE id='vera' AND status='active'" 2>/dev/null | grep -q 1; then
    ok "postgres regions.id=vera active"
  else
    bad "postgres missing active regions.id=vera"
  fi
else
  warn "rlp-postgres container not found; skip region row check"
fi

echo "=== summary pass=${PASS} fail=${FAIL} warn=${WARN} ==="
if (( FAIL > 0 )); then
  exit 1
fi
if (( STRICT == 1 && WARN > 0 )); then
  exit 1
fi
exit 0

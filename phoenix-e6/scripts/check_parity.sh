#!/usr/bin/env bash
# Pass/fail audit for phoenix-e6 / 9J45 create-ready + dense knobs + socket pin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

TARGET=phoenix-e6
STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export UV_NO_SYNC="${UV_NO_SYNC:-1}"

PASS=0
FAIL=0
WARN=0
ok() { printf 'PASS  %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf 'WARN  %s\n' "$*"; WARN=$((WARN + 1)); }

TMPDIR_PARITY="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_PARITY}"' EXIT
read_root_env() {
  local src="$1" dest="$2"
  if [[ -r "${src}" ]]; then
    cp "${src}" "${dest}"
  elif sudo -n test -f "${src}" 2>/dev/null; then
    sudo -n cat "${src}" > "${dest}" 2>/dev/null || true
  fi
  [[ -s "${dest}" ]]
}
read_root_env /etc/rlp/api.env "${TMPDIR_PARITY}/api.env" || true
read_root_env /etc/rlp/runner.env "${TMPDIR_PARITY}/runner.env" || true

env_file_has() {
  local file="$1" key="$2" want="$3" line val
  [[ -f "${file}" ]] || return 1
  line="$(grep -E "^${key}=" "${file}" | tail -n1 || true)"
  [[ -n "${line}" ]] || return 1
  val="${line#*=}"
  val="${val%\"}"; val="${val#\"}"
  [[ "${val}" == "${want}" ]]
}

env_file_int_ge() {
  local file="$1" key="$2" min="$3" line val
  [[ -f "${file}" ]] || return 1
  line="$(grep -E "^${key}=" "${file}" | tail -n1 || true)"
  [[ -n "${line}" ]] || return 1
  val="${line#*=}"
  val="${val%\"}"; val="${val#\"}"
  [[ "${val}" =~ ^[0-9]+$ ]] || return 1
  (( val >= min ))
}

echo "=== phoenix-e6 / 9J45 parity check (cwd=${ROOT}) ==="

[[ "$(uname -m)" == "x86_64" ]] && ok "host arch x86_64" || bad "host arch must be x86_64"

curl -fsS -m 5 http://127.0.0.1:8088/health >/dev/null 2>&1 \
  && ok "API health" || bad "API health"

tb_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/toolbox 2>/dev/null || echo 000)"
[[ "${tb_code}" != "000" ]] && ok "toolbox :9000 (http ${tb_code})" || bad "toolbox not reachable"

for unit in rlp-api rlp-proxy rlp-runner; do
  systemctl is-active --quiet "${unit}" 2>/dev/null && ok "systemctl ${unit} active" || bad "systemctl ${unit} not active"
done

API_ENV="${TMPDIR_PARITY}/api.env"
env_file_has "${API_ENV}" RLP_BURST_MAX_CPU 1 && ok "api.env RLP_BURST_MAX_CPU=1" || bad "api.env RLP_BURST_MAX_CPU must be 1"

RUN_ENV="${TMPDIR_PARITY}/runner.env"
env_file_has "${RUN_ENV}" RLP_SNAPSHOTS 1 && ok "runner.env RLP_SNAPSHOTS=1" || bad "runner.env RLP_SNAPSHOTS must be 1"
env_file_int_ge "${RUN_ENV}" RLP_MAX_LIVE_VMS 2500 && ok "RLP_MAX_LIVE_VMS >= 2500" || bad "RLP_MAX_LIVE_VMS must be >= 2500"
env_file_int_ge "${RUN_ENV}" RLP_NETNS_POOL 2100 && ok "RLP_NETNS_POOL >= 2100" || bad "RLP_NETNS_POOL must be >= 2100"

if [[ -f "${RUN_ENV}" ]] && grep -qE '^RLP_RUNNER_REGION=phoenix-e6$' "${RUN_ENV}"; then
  ok "runner.env RLP_RUNNER_REGION=phoenix-e6"
else
  bad "runner.env RLP_RUNNER_REGION must be phoenix-e6"
fi
if [[ -f "${RUN_ENV}" ]] && grep -qE '^RLP_RUNNER_CPU_TYPE=turin-9j45$' "${RUN_ENV}"; then
  ok "runner.env RLP_RUNNER_CPU_TYPE=turin-9j45"
else
  bad "runner.env RLP_RUNNER_CPU_TYPE must be turin-9j45"
fi
if [[ -f "${RUN_ENV}" ]] && grep -qE '^RLP_GUEST_ARCH=amd64$' "${RUN_ENV}"; then
  ok "runner.env RLP_GUEST_ARCH=amd64"
else
  bad "runner.env RLP_GUEST_ARCH must be amd64"
fi

want_cpus="$(tr -d '[:space:]' </sys/devices/system/node/node0/cpulist 2>/dev/null || true)"
want_cpus="${want_cpus:-0-95,192-287}"
cur_cpus="$(tr -d '[:space:]' </sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null || true)"
cur_mems="$(tr -d '[:space:]' </sys/fs/cgroup/rlp.slice/cpuset.mems 2>/dev/null || true)"
if [[ -z "${cur_cpus}" ]]; then
  cur_cpus="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.cpus 2>/dev/null | tr -d '[:space:]' || true)"
  cur_mems="$(sudo -n cat /sys/fs/cgroup/rlp.slice/cpuset.mems 2>/dev/null | tr -d '[:space:]' || true)"
fi
if [[ "${cur_cpus}" == "${want_cpus}" && "${cur_mems}" == "0" ]]; then
  ok "rlp.slice pinned to socket 0 (${cur_cpus} mems=${cur_mems})"
else
  bad "rlp.slice not pinned to socket 0 (cpus=${cur_cpus:-unset} mems=${cur_mems:-unset}). Run: ./o pin"
fi

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi
for var in RLP_API_URL RLP_TOOLBOX_URL RLP_API_KEY; do
  [[ -n "${!var:-}" ]] && ok ".env ${var} set" || bad ".env missing ${var}"
done
[[ "${RLP_API_URL:-}" == "http://127.0.0.1:8088" ]] && ok "RLP_API_URL localhost" || bad "RLP_API_URL must be localhost :8088"

if UV_NO_SYNC=1 uv run python -c '
from rlp import DaytonaConfig, Resources
assert "region_routing" in DaytonaConfig.__dataclass_fields__
assert "cpu_max" in Resources.__dataclass_fields__
assert "memory_max" in Resources.__dataclass_fields__
print("ok")
' >/dev/null 2>&1; then
  ok "eng rlp-sdk has region_routing + cpu_max + memory_max"
else
  bad "eng rlp-sdk missing fields (./o start)"
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx rlp-postgres; then
  if docker exec rlp-postgres psql -U rlp -d rlplatform -tAc \
    "SELECT 1 FROM regions WHERE id='phoenix-e6' AND status='active'" 2>/dev/null | grep -q 1; then
    ok "postgres regions.id=phoenix-e6 active"
  else
    bad "postgres missing active regions.id=phoenix-e6"
  fi
else
  warn "rlp-postgres container not found; skip region row check"
fi

echo "=== summary pass=${PASS} fail=${FAIL} warn=${WARN} ==="
(( FAIL == 0 )) || exit 1
(( STRICT == 0 || WARN == 0 )) || exit 1
exit 0

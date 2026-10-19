#!/usr/bin/env bash
# Build a clean daytona-agent-bench tree (no old JSONL, no other benches).
#
#   bash scripts/vendor_nvidia_repo.sh
#   bash scripts/vendor_nvidia_repo.sh /tmp/daytona-agent-bench
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERLAY="${SRC}/vendor/daytona-agent-bench"
DEST="${1:-${SRC}/.generated/daytona-agent-bench}"

if [[ ! -d "${OVERLAY}" ]]; then
  echo "missing overlay ${OVERLAY}" >&2
  exit 1
fi

if [[ -e "${DEST}/.git" && "${DEST}" -ef "${SRC}" ]]; then
  echo "refusing to write into the source repo" >&2
  exit 1
fi

mkdir -p "${DEST}"

copy_file() {
  local rel="$1"
  mkdir -p "${DEST}/$(dirname "${rel}")"
  cp "${SRC}/${rel}" "${DEST}/${rel}"
}

copy_file Dockerfile
copy_file harness/common.py
copy_file harness/rlimit_nofile.py
copy_file harness/rlp_client_tuning.py
copy_file harness/rlp_create.py
copy_file harness/env_probe.py
copy_file harness/runner_id.py
copy_file harness/rlp_snapshots.py
copy_file harness/runners/rlp.py
copy_file harness/runners/docker.py
copy_file tests/test_rlimit_nofile.py
copy_file tests/test_agent_v3.py
copy_file tests/test_rlp_hold_then_exec.py
copy_file tests/test_rlp_client_tuning.py

rsync -a \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude '.DS_Store' \
  --exclude '.venv' \
  --exclude 'repos/sqlite-utils/tests' \
  --exclude 'repos/sqlite-utils/.git' \
  --exclude 'repos/sqlite-utils/.venv' \
  "${SRC}/workload/" "${DEST}/workload/"

# Overlay wins: SETUP, slim CLI, local-only regions, empty results.
rsync -a \
  --exclude '__pycache__' \
  --exclude '.DS_Store' \
  "${OVERLAY}/" "${DEST}/"

chmod +x "${DEST}/scripts/"*.sh

# Do not copy measured JSONL. Only the schema example from the overlay.
find "${DEST}" -name 'concurrency_*.jsonl' -delete
rm -rf "${DEST}/data" "${DEST}/nvidia-agent-brief-704-zen5" \
  "${DEST}/nvidia-agent-brief-maxpack" "${DEST}/nvidia-vera-phoenix-9j45-2000" \
  "${DEST}/tickets" "${DEST}/analytics" "${DEST}/rl" "${DEST}/evals" \
  "${DEST}/media" "${DEST}/disk" "${DEST}/vendor" "${DEST}/.git"

mkdir -p "${DEST}/results"
touch "${DEST}/results/.gitkeep"

echo "wrote ${DEST}"

#!/usr/bin/env bash
# Install eng rlp-sdk (editable) into the harness .venv on a RedSwitches DUT.
# PyPI 0.3.2 lacks Resources.cpu_max / memory_max; dense2k needs those burst caps.
# Pin: daytona/rlp @ 660e6e3b (rlp-sdk 0.4.0) + fractional mem_mib patch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RLP_ROOT="${RLP_ROOT:-/home/ubuntu/rlp}"
RLP_PIN="${RLP_PIN:-660e6e3b}"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

export GIT_TERMINAL_PROMPT=0
RLP_GIT_URL="${RLP_GIT_URL:-https://github.com/danielgraviet/rlp.git}"
if [[ ! -d "${RLP_ROOT}/.git" ]]; then
  if [[ -n "${GH_TOKEN:-}" ]]; then
    auth_url="https://x-access-token:${GH_TOKEN}@${RLP_GIT_URL#https://}"
    git -c credential.helper= clone "${auth_url}" "${RLP_ROOT}"
    git -C "${RLP_ROOT}" remote set-url origin "${RLP_GIT_URL}"
  elif command -v gh >/dev/null 2>&1; then
    gh repo clone "${RLP_GIT_URL#https://github.com/}" "${RLP_ROOT}" || gh repo clone daytona/rlp "${RLP_ROOT}"
  else
    git clone "${RLP_GIT_URL}" "${RLP_ROOT}"
  fi
fi

if [[ -n "${GH_TOKEN:-}" ]]; then
  auth_url="https://x-access-token:${GH_TOKEN}@${RLP_GIT_URL#https://}"
  git -C "${RLP_ROOT}" remote set-url origin "${auth_url}"
  git -c credential.helper= -C "${RLP_ROOT}" fetch origin || true
  git -c credential.helper= -C "${RLP_ROOT}" checkout --force "${RLP_PIN}"
  git -C "${RLP_ROOT}" remote set-url origin "${RLP_GIT_URL}"
else
  git -C "${RLP_ROOT}" fetch origin || true
  git -C "${RLP_ROOT}" checkout --force "${RLP_PIN}"
fi

DAYTONA_PY="${RLP_ROOT}/clients/python/src/rlp/daytona.py"
python3 - <<PY
from pathlib import Path
p = Path("${DAYTONA_PY}")
text = p.read_text()
old = 'body["mem_mib"] = int(r.memory) * 1024'
new = 'body["mem_mib"] = int(round(float(r.memory) * 1024))'
if new in text:
    print("mem_mib patch already present")
elif old in text:
    p.write_text(text.replace(old, new, 1))
    print("applied mem_mib fractional patch")
else:
    raise SystemExit(f"mem_mib assignment not found in {p}")
PY

cd "${ROOT}"
export UV_NO_SYNC=1
uv pip install -e "${RLP_ROOT}/clients/python"
uv run python - <<'PY'
from rlp import DaytonaConfig, Resources
assert "region_routing" in DaytonaConfig.__dataclass_fields__
assert "cpu_max" in Resources.__dataclass_fields__
assert "memory_max" in Resources.__dataclass_fields__
print("eng rlp-sdk OK", Resources(cpu=0.025, memory=0.0625, disk=1, cpu_max=1, memory_max=4))
PY

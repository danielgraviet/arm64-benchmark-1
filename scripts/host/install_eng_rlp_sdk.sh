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

if [[ ! -d "${RLP_ROOT}/.git" ]]; then
  gh repo clone daytona/rlp "${RLP_ROOT}"
fi

git -C "${RLP_ROOT}" fetch origin
git -C "${RLP_ROOT}" checkout --force "${RLP_PIN}"

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

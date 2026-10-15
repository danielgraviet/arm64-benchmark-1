#!/bin/bash
# Benchmark harness + SDK on the Phoenix E6 cell. Mirrors vera-harness.sh.
set -euo pipefail
cd ~/arm64-benchmark-1
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
export PATH=$HOME/.local/bin:$PATH; uv --version

# register the local cell as a harness target
python3 - <<'PY'
import re
p="harness/regions.py"; s=open(p).read()
if '"phoenix-e6"' not in s:
    s=s.replace('    "vera": "http://127.0.0.1:9000/toolbox",',
                '    "vera": "http://127.0.0.1:9000/toolbox",\n'
                '    # On-box OCI Phoenix BM.DenseIO.E6.Ax.192 cell (EPYC 9J45 Turin).\n'
                '    "phoenix-e6": "http://127.0.0.1:9000/toolbox",',1)
    s=s.replace('    "epyc9575": "http://127.0.0.1:8088",\n    "us-phoenix-1"',
                '    "epyc9575": "http://127.0.0.1:8088",\n    "phoenix-e6": "http://127.0.0.1:8088",\n    "us-phoenix-1"',1)
    open(p,"w").write(s)
    print("regions.py: phoenix-e6 registered")
else:
    print("regions.py: phoenix-e6 already present")
PY

K=$(sudo cat /etc/rlp/bench-api-key)
cp .env .env.from-9575f 2>/dev/null || true
cat > .env <<E
RLP_API_URL=http://127.0.0.1:8088
RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
RLP_API_KEY=$K
RLP_HTTP_MAX_CONNECTIONS=4096
PHOENIX_E6_RLP_API_URL=http://127.0.0.1:8088
PHOENIX_E6_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
PHOENIX_E6_RLP_TARGET=phoenix-e6
E
chmod 600 .env

uv sync -q 2>&1 | tail -2
UV_NO_SYNC=1 uv pip install -q -e ~/rlp/clients/python 2>&1 | tail -2
UV_NO_SYNC=1 uv run python -c 'from rlp import Resources, Daytona; assert "cpu_max" in Resources.__dataclass_fields__; print("sdk ok (rlp with cpu_max)")'
grep -n 'phoenix-e6' harness/regions.py

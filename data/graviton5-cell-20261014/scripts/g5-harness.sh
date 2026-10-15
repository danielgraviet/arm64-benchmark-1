set -e
cd ~ && rm -rf arm64-benchmark-1 rlp && tar xzf ~/rlp-build/harness-g5.tgz && mkdir -p rlp && tar xzf ~/rlp-build/sdk-9575.tgz -C rlp
command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
export PATH=$HOME/.local/bin:$PATH; uv --version
cd ~/arm64-benchmark-1
K=$(sudo cat /etc/rlp/bench-api-key)
cat > .env <<E
RLP_API_URL=http://127.0.0.1:8088
RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
RLP_API_KEY=$K
G5_RLP_API_URL=http://127.0.0.1:8088
G5_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
G5_RLP_API_KEY=$K
E
chmod 600 .env
uv sync -q 2>&1 | tail -2
UV_NO_SYNC=1 uv pip install -q -e ~/rlp/clients/python 2>&1 | tail -2
UV_NO_SYNC=1 uv run python -c 'from rlp import Resources, Daytona; assert "cpu_max" in Resources.__dataclass_fields__; print("sdk ok (rlp with cpu_max)")'
UV_NO_SYNC=1 uv run python -c 'from importlib.metadata import version; print("rlp-sdk", version("rlp-sdk"))' 2>/dev/null || true
set -a; . ./.env; set +a
UV_NO_SYNC=1 uv run python -c 'from harness.regions import resolve_rlp_client_config as r; c=r("graviton5"); print("graviton5 cfg:", c.api_url, c.toolbox_url, c.target, getattr(c,"region_routing",None))'

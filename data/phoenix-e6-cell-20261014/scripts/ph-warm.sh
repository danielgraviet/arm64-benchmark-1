#!/bin/bash
# Warm the snapshot template on the Phoenix E6 cell, then verify clones are template hits.
set -uo pipefail
cd ~/arm64-benchmark-1
export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1
export RLP_API_URL=http://127.0.0.1:8088 RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
ulimit -n 65536 || true
say() { echo "[$(date -u +%T)] $*"; }

say "warmup: 2 sandboxes (miss 1 triggers the template build with RLP_TEMPLATE_BUILD_AFTER=1)"
uv run python scripts/rlp_light_create_fleet.py --target phoenix-e6 --count 2 --workers 2 \
  --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 \
  --output /tmp/ph-warm1.jsonl 2>&1 | tail -5

say "waiting for the template build"
for i in $(seq 1 60); do
  sudo journalctl -u rlp-runner --since "-10min" --no-pager -o cat 2>/dev/null | grep -qiE "template.*(built|ready|publish)" && break
  sleep 5
done
sudo journalctl -u rlp-runner --since "-10min" --no-pager -o cat | grep -iE "template" | tail -5
ls -la /mnt/data/rlp/templates 2>/dev/null | head

say "verify: 10 clones should log template=hit"
uv run python scripts/rlp_light_create_fleet.py --target phoenix-e6 --count 10 --workers 10 \
  --image dtgraviet/vera-agent-benchmark:v3 --cpu 0.025 --memory 0.0625 --disk 1.0 \
  --output /tmp/ph-warm2.jsonl 2>&1 | tail -5
sudo journalctl -u rlp-runner --since "-3min" --no-pager -o cat | grep -oE "template=[a-z]+ resume=[0-9]+ total_ms=[0-9]+ .*" | tail -10
say "fc=$(pgrep -c firecracker)"

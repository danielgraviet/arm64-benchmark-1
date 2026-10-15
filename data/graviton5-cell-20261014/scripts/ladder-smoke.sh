cd ~/arm64-benchmark-1 && export PATH=$HOME/.local/bin:$PATH UV_NO_SYNC=1 PYTHONUNBUFFERED=1 && set -a && . ./.env && set +a && export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 && ulimit -n 1048576
mkdir -p /mnt/data/bench/smoke && sudo chown -R $(id -u) /mnt/data/bench/smoke
time uv run main.py --benchmark agent --runner rlp --target graviton5 --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 44 --n 2 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625 \
  --output /mnt/data/bench/smoke/ladder-smoke.jsonl 2>&1 | tail -15
grep '"type": *"summary"' /mnt/data/bench/smoke/ladder-smoke.jsonl | cut -c1-600

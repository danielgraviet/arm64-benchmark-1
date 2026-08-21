#!/usr/bin/env bash
# Clean NVIDIA ladders: co-located client + pool 512 + hold-then-exec.
# Run Vera from rlp-control (LAN URLs). Run Phoenix from the phoenix cell API host.
# Do not drive c>=88 from a laptop SSH tunnel.
set -euo pipefail

# Vera (rlp-control): LAN cell, not laptop localhost
export VERA_RLP_API_URL="${VERA_RLP_API_URL:-http://10.96.8.181:8088}"
export VERA_RLP_TOOLBOX_URL="${VERA_RLP_TOOLBOX_URL:-http://10.96.8.181:9000/toolbox}"

echo "loadavg before: $(cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null || echo unknown)"
echo "client_host=$(hostname) VERA_RLP_API_URL=${VERA_RLP_API_URL}"

# Day 1 — Vera RL protocol proof. Gate the rest on p99 tail at 88 shrinking
# and exec-wave tput rising past the old ~53/s laptop plateau.
UV_NO_SYNC=1 uv run main.py --benchmark rl --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark-rl:latest \
  --levels 1 44 88 132 176 352 --n 5000 --seed 42 -E 8 --hold-then-exec

# Day 2 — Phoenix RL (352 optional; old Phoenix 352 was truncated)
uv run main.py --benchmark rl --runner rlp --target us-phoenix-1 \
  --snapshot dtgraviet/vera-agent-benchmark-rl:latest \
  --levels 1 44 88 132 176 --n 5000 --seed 42 -E 8 --hold-then-exec

UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:latest \
  --levels 1 44 88 132 176 --n 200 --seed 42 -E 8 --hold-then-exec

uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot dtgraviet/vera-agent-benchmark:latest \
  --levels 1 44 88 132 176 --n 200 --seed 42 -E 8 --hold-then-exec

# Day 3 — disk (E=1, pre-create so jobs/s is disk packing) + analytics
UV_NO_SYNC=1 uv run main.py --benchmark disk --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark-disk:latest \
  --levels 1 44 88 132 176 --n 128 --seed 42 -E 1 --hold-then-exec

uv run main.py --benchmark disk --runner rlp --target us-phoenix-1 \
  --snapshot dtgraviet/vera-agent-benchmark-disk:latest \
  --levels 1 44 88 132 176 --n 128 --seed 42 -E 1 --hold-then-exec

UV_NO_SYNC=1 uv run main.py --benchmark analytics --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark-analytics:latest \
  --levels 1 44 88 132 176 --n 200 --seed 42 -E 8 --hold-then-exec

uv run main.py --benchmark analytics --runner rlp --target us-phoenix-1 \
  --snapshot dtgraviet/vera-agent-benchmark-analytics:latest \
  --levels 1 44 88 132 176 --n 200 --seed 42 -E 8 --hold-then-exec

# Eng: reproduce agent coding-agent v3 (Zen 5 / Phoenix)

Paste-friendly runbook for cloning this repo and matching the latest Zen 5 ladder.
Image is already on Docker Hub (multi-arch). No image rebuild required unless you change `workload/`.

## What this is

- **Benchmark:** `agent` → task `repo-agent-v3` (default)
- **Workload:** offline coding loop inside the sandbox — seed a broken Python package → ripgrep-style search → AST walk → oracle file patches → heavy parametrized pytest. **No SQL** (legacy `repo-agent-v2` still exists but is not this ladder).
- **Harness:** RLP hold-then-exec, dedicated **1 vCPU**, **8 episodes per sandbox** (`-E 8`)
- **Fairness:** same Hub image + same flags on every target; tput = completed episodes / measured `exec_wall` (no hang-cap)

Code entrypoints:

| Piece | Path |
|-------|------|
| Workload CLI | `workload/agent.py` (`--task repo-agent-v3`) |
| Coding loop | `workload/coding_loop.py` |
| Harness spec | `harness/benchmarks.py` → `AGENT` |
| Recipe / gates | `tickets/agent-v3-ladder.md` |

## Clone + setup

```bash
git clone https://github.com/danielgraviet/arm64-benchmark-1.git
cd arm64-benchmark-1
uv sync
```

Create `.env` (gitignored) with Phoenix cell credentials:

```bash
# Required for --target us-phoenix-1
RLP_API_KEY=...          # or PHOENIX_RLP_API_KEY
# Optional overrides (defaults are already wired in harness/regions.py):
# PHOENIX_RLP_API_URL=https://api.us-phoenix-1.rlp.trydaytona.com
# PHOENIX_RLP_TOOLBOX_URL=https://toolbox.us-phoenix-1.rlp.trydaytona.com/toolbox
```

Harness loads `.env` via the RLP runner. Prefix commands with `UV_NO_SYNC=1` if you use an editable eng SDK install.

## Image (do not bake a stale :latest)

```text
dtgraviet/vera-agent-benchmark:v3
```

Also tagged `:latest` (same digest family after the v3 push). Prefer **`:v3`** so nodes do not stick on an old cached `:latest`.

Local smoke (no RLP):

```bash
uv run python -m workload.agent --n 30 --seed 42
# → one JSON line: task=repo-agent-v3, iterations=30, duration_ms, checksum
```

## Reproduce Zen 5 ladder (exact recipe used)

```bash
SNAP=dtgraviet/vera-agent-benchmark:v3
N=30
LEVELS="1 8 22 44 88 132 176 264 352 528 704"

# 1) c=1 smoke — expect p50 duration_ms roughly 6–10s, checksum_ok true, 0 failures
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot $SNAP \
  --levels 1 --n $N --seed 42 -E 8 --hold-then-exec --rlp-cpu 1

# 2) Full ladder (~25–40+ min depending on cell health)
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot $SNAP \
  --levels $LEVELS --n $N --seed 42 -E 8 --hold-then-exec --rlp-cpu 1
```

**Outputs**

- JSONL: `data/agent/rlp-phoenix/concurrency_<timestamp>_n30.jsonl`
- Each level ends with a `{"type":"summary", "concurrency": …}` line (failures, p50_duration_ms, throughput_per_sec, exec_wall_s, …)

Reference run already in repo / local data (if present):

```text
data/agent/rlp-phoenix/concurrency_20260825_191628_n30.jsonl
```

Observed on that run (for orientation, not a pass/fail gate for eng):

| Concurrency | Failures | Notes |
|-------------|----------|--------|
| 1 → 264 | 0 | Stable checksum; duration climbs with pack |
| 352 | ~66% | Mostly `DaytonaError: bad gateway: dial tcp … i/o timeout` |
| 528 / 704 | Non-zero | Same class of toolbox dial / connection errors |

Please **leave failures in the JSONL** — do not filter them for charts. Treat 352+ as Daytona connection health under load, not as a chip verdict.

## Checksum gate

Same `(n, seed)` must produce the **same** `checksum` string across hosts (and across chips when Vera is run).

```bash
# From a successful run row (no error field):
# "checksum": "<64 hex>"
```

## Vera (when you want the matched pair)

Run **on-node / colo**, not laptop SSH tunnel for c≥88. See `tickets/vera-rlp-smoke.md`.

```bash
# VERA_RLP_API_URL / VERA_RLP_API_KEY / VERA_RLP_TOOLBOX_URL required
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 1 --n 30 --seed 42 -E 8 --hold-then-exec --rlp-cpu 1
# Re-check c=1 duration in 6–10s band; then same LEVELS as Phoenix
```

Results → `data/agent/rlp-vera/`.

## Charts (optional)

```bash
uv run python eda.py --benchmark agent --include rlp-phoenix rlp-vera
# → eda_output/agent/*.png
```

## Do not change (for a matched compare)

- Image tag family (`:v3`)
- `--n 30 --seed 42 -E 8 --hold-then-exec --rlp-cpu 1`
- Level list above
- Throughput definition (completed / measured exec wall; no asymmetric hang wall)

If you change the coding loop, bump the image tag and recalibrate `n` so c=1 idle stays ~6–10s before another full ladder.

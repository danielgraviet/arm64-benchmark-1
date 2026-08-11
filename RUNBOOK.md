# RUNBOOK

## Dev
# Single-agent workload (local, no harness):
uv run python -m workload.agent --n 10
uv run python -m analytics.agent --n 2
uv run python -m rl.agent --n 64

# Concurrency harness → data/<benchmark>/<series>/concurrency_*.jsonl
# RLP default region → rlp-x86/; RLP --target arm64-test-1 → rlp-arm64/
uv run main.py --benchmark agent --runner docker --levels 1 8 22 --n 20
uv run main.py --benchmark analytics --runner docker --levels 1 8 --n 5
uv run main.py --benchmark rl --runner docker --levels 1 8 22 44 88 --n 64
uv run main.py --benchmark agent --runner e2b --levels 1 8 22 --n 20
uv run main.py --benchmark agent --runner rlp --levels 1 --n 20
uv run main.py --benchmark analytics --runner rlp --target arm64-test-1 --levels 1 --n 5
uv run main.py --benchmark rl --runner rlp --levels 1 8 22 44 88 --n 64

## Cloud snapshots / templates
Requires the matching API key in `.env`:
- Daytona: `DAYTONA_API_KEY`
- E2B: `E2B_API_KEY`
- RLP: `RLP_API_KEY` + `RLP_API_URL`

For RLP ARM64, pass `--target arm64-test-1` (do not leave an x86
`RLP_TOOLBOX_URL` sticky).

```bash
# Build per benchmark (artifact names differ)
uv run scripts/build_daytona_snapshot.py --benchmark agent
uv run scripts/build_daytona_snapshot.py --benchmark analytics
uv run scripts/build_daytona_snapshot.py --benchmark rl

uv run scripts/build_e2b_template.py --benchmark agent
uv run scripts/build_e2b_template.py --benchmark analytics
uv run scripts/build_e2b_template.py --benchmark rl

uv run scripts/build_rlp_snapshot.py --benchmark agent
uv run scripts/build_rlp_snapshot.py --benchmark analytics
uv run scripts/build_rlp_snapshot.py --benchmark rl
# ARM64: writes a *new* name (…-arm64-test-1); does not delete default-region
# vera-*-benchmark snaps
uv run scripts/build_rlp_snapshot.py --benchmark analytics --target arm64-test-1
uv run scripts/build_rlp_snapshot.py --benchmark rl --target arm64-test-1
# → snapshot vera-analytics-benchmark-arm64-test-1 / vera-rl-benchmark-arm64-test-1
uv run main.py --benchmark analytics --runner rlp --target arm64-test-1 --levels 1 --n 5
uv run main.py --benchmark rl --runner rlp --target arm64-test-1 --levels 1 --n 64

# Docker images
docker build -t vera-agent-benchmark .
docker build -f Dockerfile.analytics -t vera-analytics-benchmark .
docker build -f Dockerfile.rl -t vera-rl-benchmark .

# smoke
uv run main.py --benchmark agent --runner daytona --levels 1 --n 20
uv run main.py --benchmark analytics --runner e2b --levels 1 --n 5
uv run main.py --benchmark rl --runner docker --levels 1 --n 64
```

Region notes (RLP): `arm64-test-1` →
`https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox`. Creates also send
`cpu_arch=arm64` (resource-type selector) so jobs hit the ARM64 queue — without
it you get `no matching capacity`. Arch is probed on the builder / first worker.

## Benchmarks
- `agent` (B1): repo-agent CPU work (search / AST / edit / pytest / SQL)
- `analytics` (B2): Parquet write + DuckDB join/filter/agg (memory-bandwidth)
- `rl` (B3): mocked RL episode (sequential env/policy steps; `--n` = horizon)

Shared contract: offline image, `--n`/`--seed`, one JSON line with
`task` / `iterations` / `duration_ms` / `checksum`. See `harness/benchmarks.py`.

## EDA
# Charts from data/<benchmark>/<runner>/concurrency_*.jsonl → eda_output/<benchmark>/
uv run python eda.py --benchmark agent
uv run python eda.py --benchmark analytics
uv run python eda.py --benchmark rl

## Test
uv run pytest

## Typecheck
(none yet — no type checker configured)

## Lint
(none yet — no linter configured)

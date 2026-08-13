# RUNBOOK

## Dev
# Single-agent workload (local, no harness):
uv run python -m workload.agent --n 10
uv run python -m analytics.agent --n 2
uv run python -m rl.agent --n 64
uv run python -m evals.agent --n 1

# Concurrency harness → data/<benchmark>/<series>/concurrency_*.jsonl
# RLP default region → rlp-x86/; RLP --target arm64-test-1 → rlp-arm64/
uv run main.py --benchmark agent --runner docker --levels 1 8 22 --n 20
uv run main.py --benchmark analytics --runner docker --levels 1 8 --n 5
uv run main.py --benchmark rl --runner docker --levels 1 8 22 44 88 --n 64
# Chart A chip (daytona/rlp): heavy RL + sandbox reuse
uv run main.py --benchmark rl --runner daytona --levels 1 --n 5000 -E 8
# Chart B density: always -E 1
uv run main.py --benchmark agent --runner e2b --levels 1 8 22 --n 20
uv run main.py --benchmark agent --runner rlp --levels 1 --n 20
uv run main.py --benchmark analytics --runner rlp --target arm64-test-1 --levels 1 --n 5
uv run main.py --benchmark rl --runner rlp --levels 1 8 22 44 88 --n 64
# Optional Chart C bandwidth
uv run main.py --benchmark analytics --runner daytona --levels 1 --n 200 -E 8
# Chart B evals density (Terminal-Bench–style trials)
uv run main.py --benchmark evals --runner daytona --levels 1 8 22 44 88 --n 1 -E 1
# Phase 2: real Harbor TB oracle (not docker). --n = task limit (0=all); --levels = Harbor -n
# Requires: uv tool install 'harbor[daytona]' + DAYTONA_API_KEY
uv run main.py --benchmark tbench --runner harbor --levels 5 --n 5
uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0

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
uv run scripts/build_daytona_snapshot.py --benchmark evals

uv run scripts/build_e2b_template.py --benchmark agent
uv run scripts/build_e2b_template.py --benchmark analytics
uv run scripts/build_e2b_template.py --benchmark rl
uv run scripts/build_e2b_template.py --benchmark evals

uv run scripts/build_rlp_snapshot.py --benchmark agent
uv run scripts/build_rlp_snapshot.py --benchmark analytics
uv run scripts/build_rlp_snapshot.py --benchmark rl
uv run scripts/build_rlp_snapshot.py --benchmark evals
# ARM64: writes a *new* name (…-arm64-test-1); does not delete default-region
# vera-*-benchmark snaps
uv run scripts/build_rlp_snapshot.py --benchmark analytics --target arm64-test-1
uv run scripts/build_rlp_snapshot.py --benchmark rl --target arm64-test-1
uv run scripts/build_rlp_snapshot.py --benchmark evals --target arm64-test-1
# → snapshot vera-analytics-benchmark-arm64-test-1 / vera-rl-benchmark-arm64-test-1
uv run main.py --benchmark analytics --runner rlp --target arm64-test-1 --levels 1 --n 5
uv run main.py --benchmark rl --runner rlp --target arm64-test-1 --levels 1 --n 64

# Docker images
docker build -t vera-agent-benchmark .
docker build -f Dockerfile.analytics -t vera-analytics-benchmark .
docker build -f Dockerfile.rl -t vera-rl-benchmark .
docker build -f Dockerfile.evals -t vera-evals-benchmark .

# smoke
uv run main.py --benchmark agent --runner daytona --levels 1 --n 20
uv run main.py --benchmark analytics --runner e2b --levels 1 --n 5
uv run main.py --benchmark rl --runner docker --levels 1 --n 64
uv run main.py --benchmark evals --runner docker --levels 1 --n 1
```

Region notes (RLP): `arm64-test-1` →
`https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox`. Creates also send
`cpu_arch=arm64` (resource-type selector) so jobs hit the ARM64 queue — without
it you get `no matching capacity`. Arch is probed on the builder / first worker.

## Benchmarks
- `agent` (B1): isolated tmp workspace; search / AST / edit / pytest / SQL (`repo-agent-v2`)
- `analytics` (B2): Parquet write + DuckDB join/filter/agg (Chart C: `--n 200`)
- `rl` (B3): batched mocked RL episode (`rl-rollout-v2`; Chart A: `--n 5000 -E 8`)
- `evals` (B4): Terminal-Bench–style trials — multi-second oracle + verify, no LLM (density: `--n 1 -E 1`)
- `tbench` (Phase 2): real Harbor Terminal-Bench **oracle** via `--runner harbor` only (not docker/daytona). `--levels` = Harbor concurrency; `--n` = task limit (`0` = full pack). See `tickets/evals-terminal-bench-style.md`.

`--episodes-per-sandbox` / `-E` (daytona/rlp): create once, exec E times, delete.
Chart B density always uses `-E 1`. See `tickets/onsite-vera-gtc-runbook.md`.

Shared contract: offline image, `--n`/`--seed`, one JSON line with
`task` / `iterations` / `duration_ms` / `checksum`. See `harness/benchmarks.py`.

## EDA
# Charts from data/<benchmark>/<runner>/concurrency_*.jsonl → eda_output/<benchmark>/
uv run python eda.py --benchmark agent
uv run python eda.py --benchmark analytics
uv run python eda.py --benchmark rl
uv run python eda.py --benchmark evals

## Test
uv run pytest

## Typecheck
(none yet — no type checker configured)

## Lint
(none yet — no linter configured)

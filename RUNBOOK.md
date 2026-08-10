# RUNBOOK

## Dev
# Single agent workload (local, no harness):
uv run python -m workload.agent --n 10

# Concurrency harness (writes data/<runner>/[target/]concurrency_<ts>_n<n>.jsonl):
uv run main.py --runner docker --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner ec2 --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner daytona --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner e2b --levels 1 8 22 --n 20
uv run main.py --runner rlp --levels 1 --n 20

## Cloud snapshots / templates
Requires the matching API key in `.env`:
- Daytona: `DAYTONA_API_KEY`
- E2B: `E2B_API_KEY`
- RLP: `RLP_API_KEY` + `RLP_API_URL`

For RLP default-region jobs you may also set `RLP_TOOLBOX_URL`, but **do not**
leave an x86 toolbox URL sticky when running ARM64 — pass
`--target arm64-test-1` so the ARM64 toolbox is selected.

```bash
# Daytona cloud snapshot (once, or after workload changes)
uv run scripts/build_daytona_snapshot.py

# E2B template (once, or after workload changes)
uv run scripts/build_e2b_template.py

# RLP snapshot on the default region
uv run scripts/build_rlp_snapshot.py

# RLP snapshot on ARM64 (Graviton) — rebuild on that region; NFS is per-target
uv run scripts/build_rlp_snapshot.py --target arm64-test-1

# optional: reproduce declarative Dockerfile snapshot path (eng repro)
uv run scripts/build_daytona_snapshot_declarative.py

# smoke
uv run main.py --runner daytona --levels 1 --n 20
uv run main.py --runner e2b --levels 1 --n 20
uv run main.py --runner rlp --levels 1 --n 20

# ARM64 concurrency (results → data/rlp/arm64-test-1/)
uv run main.py --runner rlp --target arm64-test-1 --levels 1 8 22 --n 20
```

Region is selected by RLP `DaytonaConfig(target=..., toolbox_url=...)`, not by
image. Known map: `arm64-test-1` →
`https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox`. Override with
`--toolbox-url` if needed. The harness probes `platform.machine()` on the
builder / first worker (not a spare sandbox) and fails fast if an ARM64 target
returns `x86_64`. If create fails with `no matching capacity`, the ARM64 pool
is full — retry later; do not treat that as a bad toolbox URL.

Each platform has its own snapshot/template store, but builders share the same
base as Docker (`ghcr.io/astral-sh/uv:python3.13-bookworm-slim`) and install via
`uv sync --frozen --no-dev`. Rebuild the matching artifact (and local Docker
image) before comparing if the workload or base image changed.

## EDA
# Compare latest data/{docker,daytona,rlp,e2b}/*.jsonl → eda_output/*.png
uv run python eda.py

## Test
uv run pytest

## Typecheck
(none yet — no type checker configured)

## Lint
(none yet — no linter configured)

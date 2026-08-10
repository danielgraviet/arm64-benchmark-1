# RUNBOOK

## Dev
# Single agent workload (local, no harness):
uv run python -m workload.agent --n 10

# Concurrency harness (writes data/<runner>/concurrency_<ts>_n<n>.jsonl):
uv run main.py --runner docker --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner ec2 --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner daytona --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner rlp --levels 1 --n 20

## Daytona / RLP snapshots
Requires `DAYTONA_API_KEY` in `.env` for Daytona cloud.
RLP runner needs `RLP_API_KEY`, `RLP_API_URL`, `RLP_TOOLBOX_URL`.

```bash
# Daytona cloud snapshot (once, or after workload changes)
uv run scripts/build_daytona_snapshot.py

# RLP snapshot (separate registry/NFS — required for --runner rlp)
uv run scripts/build_rlp_snapshot.py

# optional: reproduce declarative Dockerfile snapshot path (eng repro)
uv run scripts/build_daytona_snapshot_declarative.py

# smoke
uv run main.py --runner daytona --levels 1 --n 20
uv run main.py --runner rlp --levels 1 --n 20
```

Each platform has its own snapshot store, but builders share the same base as
Docker (`ghcr.io/astral-sh/uv:python3.13-bookworm-slim`) and install via
`uv sync --frozen --no-dev`. Rebuild the matching snapshot (and local Docker
image) before comparing if the workload or base image changed.

## EDA
# Compare latest data/{docker,daytona,rlp}/*.jsonl → eda_output/*.png
uv run python eda.py

## Test
uv run pytest

## Typecheck
(none yet — no type checker configured)

## Lint
(none yet — no linter configured)

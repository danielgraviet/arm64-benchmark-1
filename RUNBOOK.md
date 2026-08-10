# RUNBOOK

## Dev
# Single agent workload (local, no harness):
uv run python -m workload.agent --n 10

# Concurrency harness (writes data/<runner>/concurrency_<ts>_n<n>.jsonl):
uv run main.py --runner docker --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner ec2 --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner daytona --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner rlp --levels 1 --n 20

## Daytona
Requires `DAYTONA_API_KEY` in `.env` (optional: `DAYTONA_API_URL`, `DAYTONA_TARGET`).
RLP runner uses `RLP_API_KEY` / `RLP_API_URL` instead.

```bash
# once (or after workload changes): create sandbox → upload app → snapshot
uv run scripts/build_daytona_snapshot.py

# optional: reproduce declarative Dockerfile snapshot path (eng repro)
uv run scripts/build_daytona_snapshot_declarative.py

# smoke
uv run main.py --runner daytona --levels 1 --n 20
```

The snapshot builder uses a live sandbox (not a remote Dockerfile build): upload
`workload/`, pip-install runtime deps, smoke-test `workload.agent`, stop, then
`create_snapshot`. Use `build_daytona_snapshot_declarative.py` only to reproduce
the remote `Image.from_dockerfile` build path. Latency for daytona/rlp includes
sandbox create + `process.exec` + delete. Rebuild the snapshot before comparing
against Docker if the workload changed.

## Test
uv run pytest

## Typecheck
(none yet — no type checker configured)

## Lint
(none yet — no linter configured)

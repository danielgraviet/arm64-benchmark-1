# RUNBOOK

## Dev
uv run main.py
uv run scripts/concurrency.py --levels 1 8 22 44 88 176 --n 20 --output mac_arm64_concurrency.jsonl
uv run scripts/concurrency.py --levels 1 8 22 44 88 176 --n 20 --output ecs_amd64_concurrency.jsonl

## Daytona
Requires `DAYTONA_API_KEY` in `.env` (optional: `DAYTONA_API_URL`, `DAYTONA_TARGET`).

```bash
# once (or after workload changes): create sandbox → upload app → snapshot
uv run scripts/build_daytona_snapshot.py

# optional: reproduce declarative Dockerfile snapshot path (eng repro)
uv run scripts/build_daytona_snapshot_declarative.py

# smoke
uv run scripts/concurrency_daytona.py --levels 1 --n 20 --output daytona_concurrency.jsonl

# scale up
uv run scripts/concurrency_daytona.py --levels 1 8 22 44 88 176 --n 20 --output daytona_concurrency.jsonl
```

The snapshot builder uses a live sandbox (not a remote Dockerfile build): upload
`main.py` + `workload/`, pip-install runtime deps, smoke-test, stop, then
`create_snapshot`. Use `build_daytona_snapshot_declarative.py` only to reproduce
the remote `Image.from_dockerfile` build path. Latency in the harness includes
sandbox create + `process.exec` + delete. Rebuild the snapshot before comparing
against Docker if the workload changed.

## Test
(none yet — no test suite configured)

## Typecheck
(none yet — no type checker configured)

## Lint
(none yet — no linter configured)

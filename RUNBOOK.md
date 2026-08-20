# RUNBOOK

## Dev
# Single-agent workload (local, no harness):
uv run python -m workload.agent --n 10
uv run python -m analytics.agent --n 2
uv run python -m rl.agent --n 64
uv run python -m evals.agent --n 1
uv run python -m media.agent --n 1
uv run python -m disk.agent --n 1

# Concurrency harness → data/<benchmark>/<series>/concurrency_*.jsonl
# RLP default region → rlp-x86/; --target us-phoenix-1 → rlp-phoenix/ (Zen 5 Turin, Hub image)
# RLP --target arm64-test-1 → rlp-arm64/; --target vera → rlp-vera/
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
# Phoenix Turin cell (own API). Hub images; do not pass west-1 NFS snap names.
uv run main.py --benchmark evals --runner rlp --target us-phoenix-1 --levels 1 --n 1 --seed 42 -E 1
uv run main.py --benchmark rl --runner rlp --target us-phoenix-1 --levels 1 8 22 44 88 --n 64 --seed 42 -E 8
# Optional Chart C bandwidth (analytics DuckDB and/or media FFmpeg)
uv run main.py --benchmark analytics --runner daytona --levels 1 --n 200 -E 8
uv run main.py --benchmark media --runner daytona --levels 1 --n 40 -E 8
# Daytona Linux VM vs container (same workloads; us-west-3)
# cold disk snap → daytona-vm; hot memory snap → daytona-vm-hot (RLP-ish)
uv run main.py --benchmark media --runner daytona-vm --levels 1 8 22 --n 40 -E 1
uv run main.py --benchmark media --runner daytona-vm-hot --levels 1 8 22 --n 40 -E 1
# Eng disk axis (sandbox local FS — not media/CPU): seq write + small files
uv run main.py --benchmark disk --runner daytona-vm --levels 1 8 22 44 88 --n 128 -E 1
uv run main.py --benchmark disk --runner daytona-vm-hot --levels 1 8 22 44 88 --n 128 -E 1
# Chart B evals density (log-surgery only; one task per sandbox)
uv run main.py --benchmark evals --runner daytona --levels 1 8 22 44 88 --n 1 -E 1
# Evals chip pack: same one-task-per-sandbox, warm reuse
uv run main.py --benchmark evals --runner daytona --levels 1 --n 1 --seed 42 -E 8
# Phase 2: real Harbor TB oracle (not docker). --n = task limit (0=all); --levels = Harbor -n
# Requires: uv tool install 'harbor[daytona]' + DAYTONA_API_KEY
uv run main.py --benchmark tbench --runner harbor --levels 5 --n 5
uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0

## Cloud snapshots / templates
Requires the matching API key in `.env`:
- Daytona: `DAYTONA_API_KEY`
- E2B: `E2B_API_KEY`
- RLP: `RLP_API_KEY` + `RLP_API_URL`

# Backup gitignored data/ JSONL to S3 (needs AWS creds + bucket)
# Plain sync (overwrites same keys):
uv run scripts/upload_data_s3.py --bucket YOUR_BUCKET
# Point-in-time copy under …/backups/<UTC-stamp>/data/:
uv run scripts/upload_data_s3.py --bucket YOUR_BUCKET --snapshot
# Or: VERA_DATA_S3_BUCKET=YOUR_BUCKET in .env

For RLP ARM64, pass `--target arm64-test-1` (do not leave an x86
`RLP_TOOLBOX_URL` sticky).

```bash
# Build per benchmark (artifact names differ)
uv run scripts/build_daytona_snapshot.py --benchmark agent
uv run scripts/build_daytona_snapshot.py --benchmark analytics
uv run scripts/build_daytona_snapshot.py --benchmark rl
uv run scripts/build_daytona_snapshot.py --benchmark evals
uv run scripts/build_daytona_snapshot.py --benchmark media
uv run scripts/build_daytona_snapshot.py --benchmark disk
# Linux VM snapshots in us-west-3 (cold disk + hot memory by default)
uv run scripts/build_daytona_snapshot.py --benchmark media --class linux-vm
uv run scripts/build_daytona_snapshot.py --benchmark disk --class linux-vm
uv run scripts/build_daytona_snapshot.py --benchmark rl --class linux-vm
# Cold-only or hot-only:
# uv run scripts/build_daytona_snapshot.py --benchmark media --class linux-vm --vm-snap cold
# uv run scripts/build_daytona_snapshot.py --benchmark media --class linux-vm --vm-snap hot

uv run scripts/build_e2b_template.py --benchmark agent
uv run scripts/build_e2b_template.py --benchmark analytics
uv run scripts/build_e2b_template.py --benchmark rl
uv run scripts/build_e2b_template.py --benchmark evals
uv run scripts/build_e2b_template.py --benchmark media
uv run scripts/build_e2b_template.py --benchmark disk

uv run scripts/build_rlp_snapshot.py --benchmark agent
uv run scripts/build_rlp_snapshot.py --benchmark analytics
uv run scripts/build_rlp_snapshot.py --benchmark rl
uv run scripts/build_rlp_snapshot.py --benchmark evals
uv run scripts/build_rlp_snapshot.py --benchmark media
uv run scripts/build_rlp_snapshot.py --benchmark disk
# ARM64: writes a *new* name (…-arm64-test-1); does not delete default-region
# vera-*-benchmark snaps
uv run scripts/build_rlp_snapshot.py --benchmark analytics --target arm64-test-1
uv run scripts/build_rlp_snapshot.py --benchmark rl --target arm64-test-1
uv run scripts/build_rlp_snapshot.py --benchmark evals --target arm64-test-1
uv run scripts/build_rlp_snapshot.py --benchmark media --target arm64-test-1
uv run scripts/build_rlp_snapshot.py --benchmark disk --target arm64-test-1
# → snapshot vera-analytics-benchmark-arm64-test-1 / vera-rl-benchmark-arm64-test-1
uv run main.py --benchmark analytics --runner rlp --target arm64-test-1 --levels 1 --n 5
uv run main.py --benchmark rl --runner rlp --target arm64-test-1 --levels 1 --n 64

# Docker images
docker build -t vera-agent-benchmark .
docker build -f Dockerfile.analytics -t vera-analytics-benchmark .
docker build -f Dockerfile.rl -t vera-rl-benchmark .
docker build -f Dockerfile.evals -t vera-evals-benchmark .
docker build -f Dockerfile.media -t vera-media-benchmark .
docker build -f Dockerfile.disk -t vera-disk-benchmark .

# smoke
uv run main.py --benchmark agent --runner daytona --levels 1 --n 20
uv run main.py --benchmark analytics --runner e2b --levels 1 --n 5
uv run main.py --benchmark rl --runner docker --levels 1 --n 64
uv run main.py --benchmark evals --runner docker --levels 1 --n 1
uv run main.py --benchmark media --runner docker --levels 1 --n 1
uv run main.py --benchmark disk --runner docker --levels 1 --n 1
uv run main.py --benchmark media --runner daytona-vm --levels 1 --n 1
uv run main.py --benchmark media --runner daytona-vm-hot --levels 1 --n 1
uv run main.py --benchmark disk --runner daytona-vm --levels 1 --n 1
uv run main.py --benchmark disk --runner daytona-vm-hot --levels 1 --n 1
```

Region notes (RLP): `arm64-test-1` →
`https://toolbox.arm64-test-1.rlp.trydaytona.com/toolbox`. Creates also send
`cpu_arch=arm64` (resource-type selector) so jobs hit the ARM64 queue — without
it you get `no matching capacity`. Arch is probed on the builder / first worker.

## Benchmarks
- `agent` (B1): isolated tmp workspace; search / AST / edit / pytest / SQL (`repo-agent-v2`)
- `analytics` (B2): Parquet write + DuckDB join/filter/agg (Chart C: `--n 200`)
- `rl` (B3): batched mocked RL episode (`rl-rollout-v2`; Chart A: `--n 5000 -E 8`)
- `evals` (B4): Terminal-Bench–style **log-surgery** (1.5M-line filter) — one task per sandbox (`evals-tb-style-v3`; chip: `--n 1 -E 8`; density: `--n 1 -E 1`). Rebuild the snapshot after this pin.
- `media` (Chart C sibling): FFmpeg h.264 of synthetic frames (`media-transcode-v1`; Chart C: `--n 40`)
- `disk` (eng / infra): sandbox local FS stress — sequential write/fsync/read + small-file storm (`sandbox-disk-v1`; ladder: `--n 128`). Not media; not Vera BW.
- `tbench` (Phase 2): real Harbor Terminal-Bench **oracle** via `--runner harbor` only (not docker/daytona). `--levels` = Harbor concurrency; `--n` = task limit (`0` = full pack). See `tickets/evals-terminal-bench-style.md`.

`--episodes-per-sandbox` / `-E` (daytona/rlp): create once, exec E times, delete.
Chart B density always uses `-E 1`. See `tickets/onsite-vera-gtc-runbook.md`.

Shared contract: offline image, `--n`/`--seed`, one JSON line with
`task` / `iterations` / `duration_ms` / `checksum`. See `harness/benchmarks.py`.
JSONL `type: meta` includes `env` (arch / cpu_model / host_cpu) from a one-shot
chip probe so result files are self-describing across docker/daytona/rlp.
Daytona VM run rows also record `runner_id` (SDK, else public IP via
`curl ifconfig.net`); summaries include `distinct_runners`.

## EDA
# Charts from data/<benchmark>/<runner>/concurrency_*.jsonl → eda_output/<benchmark>/
uv run python eda.py --benchmark agent
uv run python eda.py --benchmark analytics
uv run python eda.py --benchmark rl
uv run python eda.py --benchmark evals
uv run python eda.py --benchmark media
uv run python eda.py --benchmark disk

## Test
# Local / offline only (default excludes @pytest.mark.e2e)
uv run pytest
# Live cloud/network checks (RLP arm64 arch, …)
uv run pytest -m e2e

## Typecheck
(none yet — no type checker configured)

## Lint
(none yet — no linter configured)

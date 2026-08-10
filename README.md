# Vera Agent Benchmark

A portable container benchmark for measuring agent-style CPU workloads on NVIDIA Vera and comparable systems.

The benchmark is designed to run identically across different execution environments, including Daytona sandboxes and direct Docker runners.

## Goal

Measure how quickly and consistently a CPU can execute deterministic, agent-style work under increasing concurrency.

The primary outputs are:

- Per-run latency
- p50, p95, and p99 latency
- Completed workloads per second
- Maximum concurrency below a chosen latency target

## Repository Structure

```text
vera-agent-benchmark/
├── Dockerfile
├── pyproject.toml
├── uv.lock
├── main.py              # concurrency harness CLI (--runner …)
├── harness/             # shared harness + runner backends
├── workload/
│   └── agent.py         # single-agent workload (container entrypoint)
├── data/                # JSONL results (gitignored)
└── tests/
```

## Container Contract

The image must:

1. Start without downloading dependencies.
2. Run a deterministic local workload.
3. Accept command-line arguments.
4. Print one JSON result.
5. Exit with code `0` on success.

Example output:

```json
{
  "task": "repo-agent-v1",
  "iterations": 20,
  "duration_ms": 1842,
  "checksum": "abc123"
}
```

The checksum verifies that every system completed the same work.

## Dockerfile

```dockerfile
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY . .

ENV PATH="/app/.venv/bin:$PATH"

ENTRYPOINT ["python", "-m", "workload.agent"]
CMD ["--n", "10"]
```

`ENTRYPOINT` defines the program Docker runs.

`CMD` provides default arguments.

## Run

Run with the default arguments:

```bash
docker run --rm vera-agent-benchmark
```

Equivalent command inside the container:

```bash
python -m workload.agent --n 10
```

Override the arguments:

```bash
docker run --rm vera-agent-benchmark --n 20
```

Equivalent command:

```bash
python -m workload.agent --n 20
```

Run with resource limits:

```bash
docker run --rm   --cpus=1   --memory=1g   vera-agent-benchmark   --n 20
```

## Build Locally

```bash
docker build -t vera-agent-benchmark .
```

## Build for AMD64 and ARM64

```bash
docker buildx build   --platform linux/amd64,linux/arm64   -t <registry>/vera-agent-benchmark:v1   --push .
```

Do not use emulation for final performance measurements. Build and run the ARM64 image natively on Vera.

## Benchmark Workload Requirements

The workload should be:

- Deterministic
- CPU-bound or memory-bound
- Independent of external network services
- Identical across architectures
- Long enough to measure accurately
- Representative of agent tool execution

Potential operations include:

- Repository search
- Python AST parsing
- File traversal
- JSON processing
- SQLite queries
- Local code modification
- Test execution
- Compression and extraction

Avoid including:

- GitHub cloning during the timed section
- Package installation
- External API calls
- Internet access
- Random input without a fixed seed
- Architecture-specific behavior

All repositories, dependencies, and datasets should already exist inside the image.

## Suggested CLI

Single agent (inside a worker / container):

```bash
python -m workload.agent --n 20 --task repo-agent-v1 --seed 42
```

Concurrency harness (host):

```bash
uv run main.py --runner docker --levels 1 8 22 44 88 176 --n 20
uv run main.py --runner daytona --levels 1 8 --n 20
```

Results land in `data/<runner>/concurrency_<timestamp>_n<n>.jsonl`.

Suggested arguments:

- `--runner`: `docker` | `daytona` | `rlp` | `ec2`
- `--levels`: Concurrency levels to sweep
- `--n`: Workload volume per run
- `--seed`: Fixed random seed
- `--output`: Optional JSONL path override

## Concurrency Testing

The external runner should launch multiple independent containers:

```bash
docker run --rm vera-agent-benchmark --n 20
```

Suggested concurrency levels:

```text
1, 8, 22, 44, 88, 176
```

Concurrency should be controlled outside the container. Each container should execute one independent benchmark run.

## Measurement Rules

For the primary benchmark:

- Pre-pull the image.
- Warm the filesystem cache separately if testing warm performance.
- Do not include image download time.
- Do not include package installation.
- Record both cold and warm runs explicitly.
- Use the same CPU and memory limits.
- Run enough repetitions to calculate tail latency.
- Store the raw result from every run.

Do not rely only on average latency. Report:

- p50
- p95
- p99
- Maximum
- Throughput

## Success Criteria

The benchmark is ready when this command produces a deterministic JSON result on both AMD64 and ARM64:

```bash
docker run --rm vera-agent-benchmark --n 20
```

The same checksum should be produced on both architectures.

# Why we selected 111 tests

We vendored `sqlite-utils` (pinned at tag 4.1.1) as the single target repo for the workload, since its core purpose is SQLite querying/manipulation and it needs no artificial SQLite step bolted on. Out of its ~742 tests, we picked a fixed subset of 111 that run with no network calls, no unseeded randomness, and no compiled/platform-specific dependencies, chosen to exercise a variety of distinct CPU and memory muscles rather than overlapping CLI wrappers around the same logic.

| File | Tests | CPU muscle |
|---|---|---|
| test_fts.py | 51 | Tokenization/indexing — builds FTS index tables |
| test_analyze_tables.py | 16 | Full column scans, distinct-value counting |
| test_m2m.py | 11 | Multi-table join queries |
| test_extract.py | 15 | Lookup-table extraction/dedup from repeated values |
| test_upsert.py | 18 | Repeated insert/update cycles keyed on hashed PKs |

# Using RLP / Daytona

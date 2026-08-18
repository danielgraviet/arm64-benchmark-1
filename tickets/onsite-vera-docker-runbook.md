# Onsite Vera — local Docker runbook

**When:** SSH on the Vera node; network restricted; sandboxes = **local Docker**.  
**Assumes:** repo cloned, images built, smokes already green.  
**Runner:** `--runner docker` only. No `--target`. No Daytona/RLP.

**How to use:** one command per block. Copy/paste. Results → `data/<bench>/docker/`.

### Flags (Docker)

| Flag | Meaning |
| --- | --- |
| `--runner docker` | One local container per worker |
| `--seed 42` | Fixed RNG / checksums |
| `--levels …` | Concurrent containers (not work size) |
| `--n` | Work size **inside** one container (meaning differs by pack) |

**Note:** `-E` / `--episodes-per-sandbox` is **Daytona/RLP only**. Docker always creates a fresh container per job. Chip claim still uses **`duration_ms`** (in-container), not wall create time.

---

## Chart A — chip (`duration_ms`)

Heavy RL. Look at `duration_ms` p50/p99, not cold wall latency.

```bash
uv run main.py --benchmark rl --runner docker --levels 1 88 --n 5000 --seed 42
```

Optional Chart C (if time; keep only if Vera `duration_ms` wins):

```bash
uv run main.py --benchmark analytics --runner docker --levels 1 88 --n 200 --seed 42
```

```bash
uv run main.py --benchmark media --runner docker --levels 1 88 --n 40 --seed 42
```

---

## Chart B — density (throughput + p99)

Fresh container per job. Full ladder.

```bash
uv run main.py --benchmark rl --runner docker --levels 1 8 22 44 88 --n 64 --seed 42
```

```bash
uv run main.py --benchmark agent --runner docker --levels 1 8 22 44 88 --n 20 --seed 42
```

```bash
uv run main.py --benchmark evals --runner docker --levels 1 8 22 44 88 --n 1 --seed 42
```

Optional density siblings (if time):

```bash
uv run main.py --benchmark disk --runner docker --levels 1 8 22 44 88 --n 128 --seed 42
```

```bash
uv run main.py --benchmark analytics --runner docker --levels 1 8 22 44 88 --n 10 --seed 42
```

```bash
uv run main.py --benchmark media --runner docker --levels 1 8 22 44 88 --n 40 --seed 42
```

---

## After runs — EDA (on this node or copy JSONL off)

```bash
uv run python eda.py --benchmark rl
```

```bash
uv run python eda.py --benchmark agent
```

```bash
uv run python eda.py --benchmark evals
```

```bash
uv run python eda.py --benchmark analytics
```

```bash
uv run python eda.py --benchmark media
```

```bash
uv run python eda.py --benchmark disk
```

---

## Quick param cheat sheet

| Chart | Pack | `--levels` | `--n` | Why that `--n` |
| --- | --- | --- | --- | --- |
| A | `rl` | `1 88` | `5000` | Heavy episode (~multi-second `duration_ms`) |
| C | `analytics` | `1 88` | `200` | DuckDB / mem-BW |
| C | `media` | `1 88` | `40` | FFmpeg frames = n×90 |
| B | `rl` | `1 8 22 44 88` | `64` | Light; density / create-dominated |
| B | `agent` | `1 8 22 44 88` | `20` | Coding-agent density |
| B | `evals` | `1 8 22 44 88` | `1` | One TB-style trial per container |
| eng | `disk` | `1 8 22 44 88` | `128` | ~128 MiB + small files |

---

## Rebuild images (only if needed)

```bash
docker build -t vera-agent-benchmark .
```

```bash
docker build -f Dockerfile.analytics -t vera-analytics-benchmark .
```

```bash
docker build -f Dockerfile.rl -t vera-rl-benchmark .
```

```bash
docker build -f Dockerfile.evals -t vera-evals-benchmark .
```

```bash
docker build -f Dockerfile.media -t vera-media-benchmark .
```

```bash
docker build -f Dockerfile.disk -t vera-disk-benchmark .
```

---

## Read guide

| Chart | Look at | Ignore for the claim |
| --- | --- | --- |
| A (chip) | `duration_ms` p50/p99 | container start wall `latency_ms` |
| B (density) | `throughput_per_sec`, `p99_ms`; flat `duration_ms` at 88 | treating start tax as “Vera cores” |

**JSONL:** `data/<benchmark>/docker/concurrency_*_n*.jsonl` — meta has `n` + `seed`; each summary has `concurrency`.

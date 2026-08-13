# Daytona vs RLP concurrency ladder

**Goal:** Compare container Daytona vs RLP at customer concurrency (100 = normal, 1k = high-value). Chart B density: evals `--n 1 -E 1`.

**How to use:** copy/paste one command at a time. Sequential. Stop if a level has failures or ugly tails before climbing.

Default RLP region (x86). Do not pass `--target` unless you intend ARM64.

---

## Snapshots (skip if already built)

```bash
uv run scripts/build_daytona_snapshot.py --benchmark evals
```

```bash
uv run scripts/build_rlp_snapshot.py --benchmark evals
```

---

## Smoke (c=1)

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner rlp --levels 1 --n 1 --seed 42 -E 1
```

---

## 100 concurrent

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 100 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner rlp --levels 1 100 --n 1 --seed 42 -E 1
```

---

## 1k concurrent (only if 100 is clean)

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 100 1000 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner rlp --levels 1 100 1000 --n 1 --seed 42 -E 1
```

---

## Optional — coding-agent sibling

```bash
uv run scripts/build_daytona_snapshot.py --benchmark agent
```

```bash
uv run scripts/build_rlp_snapshot.py --benchmark agent
```

```bash
uv run main.py --benchmark agent --runner daytona --levels 1 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner rlp --levels 1 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner daytona --levels 1 100 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner rlp --levels 1 100 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner daytona --levels 1 100 1000 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner rlp --levels 1 100 1000 --n 20 --seed 42 -E 1
```

---

## EDA

```bash
uv run python eda.py --benchmark evals
```

```bash
uv run python eda.py --benchmark agent
```

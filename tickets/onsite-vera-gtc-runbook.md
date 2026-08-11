# Onsite Vera / NVIDIA HQ runbook

**Goal:** Leave HQ with a small set of clean JSONL files that support Chart A (chip) and Chart B (Daytona density). EDA + slides happen after.

**Related:** `tickets/gtc-berlin-vera-daytona-compelling-data.md`

**Do not** spray every `--n` on every benchmark. Intentional matrix only.

---

## Before you start

- [ ] Repo checked out, `uv sync` works
- [ ] Creds for Daytona / RLP that can hit the Vera region
- [ ] Know the Vera `--target` name (fill in below once you have it)
- [ ] Control recipe already validated on Daytona default (`rl` at `n=100000` or `200000`)
- [ ] Same `--seed` everywhere: **`42`** (unless you deliberately change it and re-run both sides)

**Fill in onsite:**

| Item | Value |
| --- | --- |
| Vera `--target` | `<vera-region>` |
| Runner for Vera | `rlp` or `daytona` (whichever the node is on) |
| Control runner | `daytona` (default) and/or `rlp` (no target / x86) |
| Chart A `--n` | `100000` (or `200000` if time) |
| Seed | `42` |

---

## Snapshots (do this first)

Build once per (benchmark × region). Same workload image on Vera and control.

```bash
# RL (required)
uv run scripts/build_rlp_snapshot.py --benchmark rl --target <vera-region>
# also ensure control-region RL snapshot exists

# Agent (Chart B)
uv run scripts/build_rlp_snapshot.py --benchmark agent --target <vera-region>

# Analytics (optional only)
uv run scripts/build_rlp_snapshot.py --benchmark analytics --target <vera-region>
```

If using Daytona as the Vera path, build the Daytona snapshot for that region / naming scheme the same way you did for default.

Smoke test before the matrix:

```bash
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 --n 64 --seed 42
```

Confirm: exit 0, checksum present, `duration_ms` in the JSONL run row.

---

## Priority order (stick to this)

### 1) Chart A — is the chip itself faster?

Same heavy RL episode on Vera and control. Compare **`duration_ms` only**.

```bash
# Vera
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 88 --n 100000 --seed 42

# Control (Daytona default example)
uv run main.py --benchmark rl --runner daytona --levels 1 88 --n 100000 --seed 42
```

**Pass if:** Vera `duration_ms` p50 is clearly lower (≥20–30%).  
**Fail / drop chip brag if:** flat, noisy, or Vera slower. Still keep the files.

Checksums for the same `(n, seed)` must match across regions.

### 2) Chart B — can Daytona pack work onto Vera?

Light workload, many sandboxes. Check throughput up, usable p99, episode CPU roughly flat.

```bash
# Light RL density
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 64 --seed 42

# Agent density (customer-shaped)
uv run main.py --benchmark agent --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 20 --seed 42
```

Optional control for B if you want a side-by-side density slide:

```bash
uv run main.py --benchmark rl --runner daytona --levels 1 8 22 44 88 --n 64 --seed 42
uv run main.py --benchmark agent --runner daytona --levels 1 8 22 44 88 --n 20 --seed 42
```

### 3) Optional — analytics (only if time)

Mid/high `--n`. Keep only if Vera wins on `duration_ms` / throughput; else appendix.

```bash
uv run main.py --benchmark analytics --runner rlp --target <vera-region> --levels 1 88 --n 20 --seed 42
# bump --n if duration_ms is still tiny vs create tax
```

---

## What to collect (files)

JSONL lands under `data/<benchmark>/<runner>/` (target suffix dirs for RLP targets).

Minimum leave-with set:

| File role | Benchmark | `--n` | Levels | Regions |
| --- | --- | --- | --- | --- |
| Chart A Vera | `rl` | 100000 (or 200000) | 1 88 | Vera |
| Chart A control | `rl` | same | 1 88 | Daytona default and/or rlp-x86 |
| Chart B RL | `rl` | 64 | 1 8 22 44 88 | Vera (+ optional control) |
| Chart B agent | `agent` | 20 | 1 8 22 44 88 | Vera (+ optional control) |
| Optional C | `analytics` | mid/high | 1 88 | Vera + control |

That’s enough. Do **not** sweep every `n`.

---

## How to read results onsite (quick)

- **Chart A:** look at run-row `duration_ms` (p50 / p99). Ignore mean wall `latency_ms` for the chip claim.
- **Chart B:** look at summary `throughput_per_sec` and `p99_ms`; spot-check that `duration_ms` doesn’t explode at 88.
- Confirm `checksum_ok: true` on summaries.

EDA after the visit (latency/throughput today; `duration_ms` charts may need a quick hand pull from JSONL):

```bash
uv run python eda.py --benchmark rl
uv run python eda.py --benchmark agent
```

---

## Decision rule (lock the slide before you leave)

- [ ] If **A** wins clearly → lead with **chip + density**
- [ ] If **A** is flat/noisy but **B** is strong → lead with **Daytona scales on Vera** (don’t overclaim FLOPs)
- [ ] Never headline light-`n` create/API latency as “Vera cores are faster”
- [ ] Don’t use current `arm64-test-1` / `rlp-arm64` as the Vera chip proof

One sentence to fill in:

> On Vera, Daytona runs **88 concurrent** customer rollouts with **stable per-episode CPU**, and those episodes finish **___% faster** than on today’s region *(only if Chart A supports it)*.

---

## Timebox if you’re short

1. Smoke `rl` c=1 on Vera  
2. Chart A only (`rl` heavy, c=1 is enough if 88 is slow; add 88 if possible)  
3. Chart B light `rl` `1→88`  
4. Skip agent / analytics  

---

## Anti-goals

- Don’t up `--n` on every bench “just in case”
- Don’t collect a ton of exploratory JSONL with no control twin
- Don’t decide the GTC headline from wall `latency_ms` alone

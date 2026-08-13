# Onsite Vera / NVIDIA HQ runbook

**Goal:** Leave HQ with clean JSONL for Chart A (chip) and Chart B (density). EDA + slides after.

**Related:** `tickets/gtc-berlin-vera-daytona-compelling-data.md`

**How to use this doc:** every runnable command is on its **own line**. Copy/paste one at a time (or split terminals for snapshot builds). Replace `<vera-region>` everywhere once you know the target name.

| Item | Value |
| --- | --- |
| Vera `--target` | `<vera-region>` |
| Seed | `42` |
| Chart A RL `--n` | `5000` (hardened batched policy; ~4.6s `duration_ms` on Daytona) |
| Chart A `-E` | `8` (sandbox reuse — warm episodes) |
| Chart B RL `--n` | `64` |
| Chart B agent `--n` | `20` |
| Chart B evals `--n` | `1` (one TB-style task per sandbox) |
| Chart B `-E` | `1` (fresh sandbox per episode — density) |
| Chart C analytics `--n` | `200` (optional) |
| Chart C media `--n` | `40` (optional FFmpeg bandwidth sibling) |

---

## Day overview (3 days)

| Day | Focus |
| --- | --- |
| **Day 1** | Land, snapshots, smokes, inspect, short reuse smoke |
| **Day 2** | Chart A chip (`duration_ms`, Vera vs control, `-E 8`) |
| **Day 3** | Chart B density (`E=1` ladder) + lock Berlin headline |

---

## Before you start (prep / Day 0)

- [ ] Repo synced with hardened workloads (`rl-rollout-v2`, `repo-agent-v2`)
- [ ] `.env` has RLP / Daytona creds for the new region
- [ ] `<vera-region>` added to `harness/regions.py` (`RLP_TARGET_TOOLBOX` + `RLP_TARGET_CPU_ARCH`)
- [ ] You can open 3 terminals in this repo

---

## Day 1 — snapshots + smoke + inspect

### 1a. Build snapshots (parallel — up to 5 terminals)

```bash
uv run scripts/build_rlp_snapshot.py --benchmark rl --target <vera-region>
```

```bash
uv run scripts/build_rlp_snapshot.py --benchmark agent --target <vera-region>
```

```bash
uv run scripts/build_rlp_snapshot.py --benchmark analytics --target <vera-region>
```

```bash
uv run scripts/build_rlp_snapshot.py --benchmark evals --target <vera-region>
```

```bash
uv run scripts/build_rlp_snapshot.py --benchmark media --target <vera-region>
```

Wait until all five finish successfully.

### 1b. Smoke runs on the new region (c=1, sequential)

```bash
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 --n 64 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner rlp --target <vera-region> --levels 1 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark analytics --runner rlp --target <vera-region> --levels 1 --n 5 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner rlp --target <vera-region> --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner rlp --target <vera-region> --levels 1 --n 1 --seed 42 -E 1
```

### 1c. Sandbox-reuse smoke (Chart A plumbing)

```bash
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 --n 1000 --seed 42 -E 4
```

### Task: inspect before Day 2

Open the newest JSONL under `data/<bench>/rlp-*/`.

- [ ] Exit 0 / `failures: 0` / `checksum_ok: true`
- [ ] Run rows have `duration_ms` > 0
- [ ] Reuse smoke: `episode_idx` 0…3, only idx 0 has `"cold": true`, checksums match across episodes
- [ ] Arch probe looks right for Vera

**Stop if anything looks off.** Fix before Day 2.

---

## Day 2 — Chart A main evaluation loop (sequential)

Same heavy RL episode. Compare **`duration_ms` only** for the chip claim. `-E 8` warms the sandbox so wall latency on warm episodes tracks compute.

```bash
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 88 --n 5000 --seed 42 -E 8
```

```bash
uv run main.py --benchmark rl --runner daytona --levels 1 88 --n 5000 --seed 42 -E 8
```

Optional RLP x86 control:

```bash
uv run main.py --benchmark rl --runner rlp --levels 1 88 --n 5000 --seed 42 -E 8
```

Optional Chart C (only if time; keep only if Vera wins on `duration_ms`):

```bash
uv run main.py --benchmark analytics --runner rlp --target <vera-region> --levels 1 88 --n 200 --seed 42 -E 8
```

```bash
uv run main.py --benchmark analytics --runner daytona --levels 1 88 --n 200 --seed 42 -E 8
```

```bash
uv run main.py --benchmark media --runner rlp --target <vera-region> --levels 1 88 --n 40 --seed 42 -E 8
```

```bash
uv run main.py --benchmark media --runner daytona --levels 1 88 --n 40 --seed 42 -E 8
```

**Pass if:** Vera `duration_ms` p50 clearly lower (≥20–30%).  
**Else:** drop chip brag; still keep files for density day.

---

## Day 3 — Chart B density + lock slide (sequential)

Light workloads, full ladder, **`-E 1`** (one create per sandbox — this is density, not reuse).

```bash
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 64 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark rl --runner daytona --levels 1 8 22 44 88 --n 64 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner daytona --levels 1 8 22 44 88 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
```

### After runs — EDA

```bash
uv run python eda.py --benchmark rl
```

```bash
uv run python eda.py --benchmark agent
```

```bash
uv run python eda.py --benchmark analytics
```

```bash
uv run python eda.py --benchmark evals
```

```bash
uv run python eda.py --benchmark media
```

---

## Optional — Harbor TB oracle (Phase 2, after density)

Not Day-1 P0. Requires `uv tool install 'harbor[daytona]'` and `DAYTONA_API_KEY`.
Do **not** use `--runner docker` for real Terminal-Bench.

```bash
uv run main.py --benchmark tbench --runner harbor --levels 5 --n 5
```

```bash
uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0
```

```bash
uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0 --target <vera-region>
```

Compare wall time-to-finish / JSONL under `data/tbench/harbor/`. Oracle pass rate should be ≈1.0. Details: `tickets/evals-terminal-bench-style.md`.

### Lock the Berlin sentence

- [ ] If Chart A wins clearly → lead with **chip + density**
- [ ] If A flat/noisy but B strong → lead with **Daytona scales on Vera**
- [ ] Never headline light-`n` create/API latency as “Vera cores are faster”
- [ ] Don’t use `arm64-test-1` as Vera chip proof

> On Vera, Daytona runs **88 concurrent** customer rollouts with **stable per-episode CPU**, and those episodes finish **___% faster** than on today’s region *(only if Chart A supports it)*.

---

## Quick read guide

| Chart | Look at | Ignore for the claim |
| --- | --- | --- |
| A (chip) | `duration_ms` p50/p99; warm `p50_warm_ms` as cross-check | cold create `latency_ms` |
| B (density) | `throughput_per_sec`, `p99_ms`; flat `duration_ms` at 88 | reuse / `-E>1` |

---

## Anti-goals

- Don’t start Day 2 before Day 1 inspect is green
- Don’t run Chart B with `-E > 1` and call it density
- Don’t spray every `--n` on every bench
- Don’t decide the GTC headline from wall `latency_ms` alone

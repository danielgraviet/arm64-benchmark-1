# Onsite Vera / NVIDIA HQ runbook

**Goal:** Leave HQ with clean JSONL for Chart A (chip) and Chart B (density) on the **Vera Daytona region**. EDA + slides after. Default-region Daytona controls run **after** Vera time (limited node access).

**Related:** `tickets/gtc-berlin-vera-daytona-compelling-data.md`

**How to use this doc:** every runnable command is on its **own line**. Copy/paste one at a time (or split terminals for snapshot builds). Replace `<vera-region>` everywhere once you know the target name.

### Shared flags (same meaning on every pack)

| Flag | Meaning |
| --- | --- |
| `--runner daytona` | Daytona container sandboxes (onsite) |
| `--target <vera-region>` | Vera region — required on every onsite command |
| `--seed 42` | Fixed RNG so checksums match across runners |
| `--levels …` | **How many sandboxes at once** (concurrency). `1` = one sandbox; `1 8 22 44 88` = density ladder. Not work size. |
| `-E` / `--episodes-per-sandbox` | **How many jobs per sandbox before delete.** `-E 1` = fresh sandbox each time (density). `-E 8` = create once, run 8 times (chip / warm reuse). |

`--n` is **work size inside one sandbox**. It means something different per pack — see below.

### Final run params by task

**Chart A — chip** (`duration_ms` only; ignore create tax)

| Pack | What `--n` means | Final params | Why |
| --- | --- | --- | --- |
| **`rl`** | Mocked rollout steps | `--levels 1 88 --n 5000 -E 8` | Heavy episode (~4.6s `duration_ms` on Daytona). `-E 8` so warm wall time tracks chip, not create. |

**Chart B — density** (throughput + p99; fresh sandbox each job)

| Pack | What `--n` means | Final params | Why |
| --- | --- | --- | --- |
| **`rl`** | Mocked rollout steps | `--levels 1 8 22 44 88 --n 64 -E 1` | Light episode so create/schedule dominates; tests packing many sandboxes. |
| **`agent`** | Repo-agent work units | `--levels 1 8 22 44 88 --n 20 -E 1` | Coding-agent–shaped density. |
| **`evals`** | Number of TB-style trials *inside* one sandbox | `--levels 1 8 22 44 88 --n 1 -E 1` | One eval trial per sandbox — closest to Terminal-Bench–on-Daytona load. |

**Chart C — optional bandwidth** (only if time; keep if Vera wins on `duration_ms`)

| Pack | What `--n` means | Final params | Why |
| --- | --- | --- | --- |
| **`analytics`** | Synthetic table scale (customers/orders/items) | `--levels 1 88 --n 200 -E 8` | Multi-second DuckDB / mem-BW spike. |
| **`media`** | Frame count scale (`frames = n × 90`) | `--levels 1 88 --n 40 -E 8` | FFmpeg h.264 sibling; non-Python BW. |

**Eng / infra — disk** (sandbox local FS; not a chip or Chart C claim)

| Pack | What `--n` means | Final params | Why |
| --- | --- | --- | --- |
| **`disk`** | MiB sequential write + `n×64` small files | `--levels 1 8 22 44 88 --n 128 -E 1` | Stress sandbox disk under density. |

**Smokes (Day 1):** always `--levels 1 -E 1` with a small `--n` (see §1b) — wiring check only, not headline data.

**Packs on Vera (all six):** `rl`, `agent`, `analytics`, `evals`, `media`, `disk`

---

## Day overview (3 days)

| Day | Focus |
| --- | --- |
| **Day 1** | Land, Daytona snapshots on Vera, smokes, inspect, short reuse smoke |
| **Day 2** | Chart A chip on Vera (`duration_ms`, `-E 8`) — no default-region control on-site |
| **Day 3** | Chart B density on Vera (`E=1` ladder) + lock Berlin headline |

**After Vera time:** default-region Daytona controls + optional VM / Harbor work.

---

## Before you start (prep / Day 0)

- [ ] Repo synced with hardened workloads (`rl-rollout-v2`, `repo-agent-v2`, media, disk)
- [ ] `.env` has `DAYTONA_API_KEY` for the Vera region
- [ ] `<vera-region>` name known (pass as `--target` on every onsite command)
- [ ] You can open several terminals in this repo

---

## Day 1 — snapshots + smoke + inspect

### 1a. Build Daytona snapshots on Vera (parallel — up to 6 terminals)

```bash
uv run scripts/build_daytona_snapshot.py --benchmark rl --target <vera-region>
```

```bash
uv run scripts/build_daytona_snapshot.py --benchmark agent --target <vera-region>
```

```bash
uv run scripts/build_daytona_snapshot.py --benchmark analytics --target <vera-region>
```

```bash
uv run scripts/build_daytona_snapshot.py --benchmark evals --target <vera-region>
```

```bash
uv run scripts/build_daytona_snapshot.py --benchmark media --target <vera-region>
```

```bash
uv run scripts/build_daytona_snapshot.py --benchmark disk --target <vera-region>
```

Wait until all six finish successfully.

### 1b. Smoke runs on Vera (c=1, sequential)

```bash
uv run main.py --benchmark rl --runner daytona --target <vera-region> --levels 1 --n 64 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner daytona --target <vera-region> --levels 1 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark analytics --runner daytona --target <vera-region> --levels 1 --n 5 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner daytona --target <vera-region> --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona --target <vera-region> --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark disk --runner daytona --target <vera-region> --levels 1 --n 1 --seed 42 -E 1
```

### 1c. Sandbox-reuse smoke (Chart A plumbing)

```bash
uv run main.py --benchmark rl --runner daytona --target <vera-region> --levels 1 --n 1000 --seed 42 -E 4
```

### Task: inspect before Day 2

Open the newest JSONL under `data/<bench>/daytona/`.

- [ ] Exit 0 / `failures: 0` / `checksum_ok: true`
- [ ] Run rows have `duration_ms` > 0
- [ ] Reuse smoke: `episode_idx` 0…3, only idx 0 has `"cold": true`, checksums match across episodes
- [ ] `meta.env` / arch probe looks right for Vera

**Stop if anything looks off.** Fix before Day 2.

---

## Day 2 — Chart A main evaluation loop (Vera only, sequential)

Same heavy RL episode on **Vera**. Compare **`duration_ms` only** for the chip claim. `-E 8` warms the sandbox so wall latency on warm episodes tracks compute.

Do **not** burn Vera time on default-region Daytona controls — run those after (see below).

```bash
uv run main.py --benchmark rl --runner daytona --target <vera-region> --levels 1 88 --n 5000 --seed 42 -E 8
```

Optional Chart C on Vera (only if time; keep only if Vera wins on `duration_ms`):

```bash
uv run main.py --benchmark analytics --runner daytona --target <vera-region> --levels 1 88 --n 200 --seed 42 -E 8
```

```bash
uv run main.py --benchmark media --runner daytona --target <vera-region> --levels 1 88 --n 40 --seed 42 -E 8
```

**Pass if:** Vera `duration_ms` p50 is strong vs the control you’ll run later (≥20–30%).  
**Else:** drop chip brag; still keep files for density day.

---

## Day 3 — Chart B density + lock slide (Vera only, sequential)

Light workloads, full ladder, **`-E 1`** (one create per sandbox — this is density, not reuse).

```bash
uv run main.py --benchmark rl --runner daytona --target <vera-region> --levels 1 8 22 44 88 --n 64 --seed 42 -E 1
```

```bash
uv run main.py --benchmark agent --runner daytona --target <vera-region> --levels 1 8 22 44 88 --n 20 --seed 42 -E 1
```

```bash
uv run main.py --benchmark evals --runner daytona --target <vera-region> --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
```

If time remains on Vera, optional density siblings:

```bash
uv run main.py --benchmark disk --runner daytona --target <vera-region> --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
```

```bash
uv run main.py --benchmark analytics --runner daytona --target <vera-region> --levels 1 8 22 44 88 --n 10 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona --target <vera-region> --levels 1 8 22 44 88 --n 40 --seed 42 -E 1
```

### After Vera runs — EDA

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

```bash
uv run python eda.py --benchmark disk
```

---

## After Vera time — default-region Daytona controls

Run these **after** the onsite window so Chart A / B can be compared Vera vs today’s Daytona without burning node time.

```bash
uv run scripts/build_daytona_snapshot.py --benchmark rl
```

```bash
uv run main.py --benchmark rl --runner daytona --levels 1 88 --n 5000 --seed 42 -E 8
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

Optional Chart C / disk controls:

```bash
uv run main.py --benchmark analytics --runner daytona --levels 1 88 --n 200 --seed 42 -E 8
```

```bash
uv run main.py --benchmark media --runner daytona --levels 1 88 --n 40 --seed 42 -E 8
```

```bash
uv run main.py --benchmark disk --runner daytona --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
```

---

## Optional — Daytona Linux VM vs container (us-west-3, after Vera)

Same workloads. Eng: VM seeds live in **`us-west-3`** (not default `us`).
Builder writes **cold** (`vera-*-benchmark-vm`) and **hot memory** (`vera-*-benchmark-vm-hot`) snaps.

| Series | Runner | Boot |
| --- | --- | --- |
| `daytona` | `--runner daytona` | container |
| `daytona-vm` | `--runner daytona-vm` | VM cold disk |
| `daytona-vm-hot` | `--runner daytona-vm-hot` | VM hot/memory |

```bash
uv run scripts/build_daytona_snapshot.py --benchmark media --class linux-vm
```

```bash
uv run scripts/build_daytona_snapshot.py --benchmark disk --class linux-vm
```

```bash
uv run main.py --benchmark media --runner daytona-vm --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona-vm-hot --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona-vm --levels 1 8 22 44 88 --n 40 --seed 42 -E 1
```

```bash
uv run main.py --benchmark media --runner daytona-vm-hot --levels 1 8 22 44 88 --n 40 --seed 42 -E 1
```

Disk axis (sandbox local FS — not media/CPU BW). Eng ladder `--n 128`:

```bash
uv run main.py --benchmark disk --runner daytona-vm --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark disk --runner daytona-vm-hot --levels 1 --n 1 --seed 42 -E 1
```

```bash
uv run main.py --benchmark disk --runner daytona-vm --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
```

```bash
uv run main.py --benchmark disk --runner daytona-vm-hot --levels 1 8 22 44 88 --n 128 --seed 42 -E 1
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
- Don’t spray every `--n` on every bench during Vera time
- Don’t burn Vera time on default-region controls (do those after)
- Don’t decide the GTC headline from wall `latency_ms` alone

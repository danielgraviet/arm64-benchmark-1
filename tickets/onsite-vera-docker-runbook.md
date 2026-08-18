# Onsite Vera — local Docker data haul

**Goal:** Burn **Vera node time** collecting as much Docker JSONL as possible for later EDA / x86 comparison. Onsite is scarce; x86 controls are **after**.

**Runner:** `--runner docker` only. No `--target`. No `-E` (Docker = fresh container each job).  
**Compare later:** `duration_ms` for chip; wall latency / throughput for density.  
**Host (confirmed):** `aarch64`, 352 CPUs, `cpu_model=0x010`, probe=docker.

**Rule:** Finish higher priority before lower. Skip a block only if the node window ends — note what you skipped so x86 can match.

---

## Priority map (Vera first)

| Pri | Theme | Why now | Est. wall (order-of-mag) |
| --- | --- | --- | --- |
| **P0** | Chip baseline (done) | Headline `duration_ms` @ c=1 | — already collected |
| **P1** | Chip depth | More repeats + fix weak agent signal | ~15–30 min |
| **P2** | Heavy ladders | Same heavy `--n` across `1 8 22 44 88` — chip under contention | ~1–3 h |
| **P3** | Density ladders | Light `--n` packing / Chart B on this host | ~30–60 min |
| **P4** | n-sweeps + alt seeds | Scaling curves + variance for EDA | until time runs out |
| **AFTER** | x86 Docker mirror | Apples-to-apples controls | post-onsite |

Do **not** spend Vera time on Daytona / RLP / Harbor — those are not node-bound the same way. See `onsite-vera-gtc-runbook.md` if the cloud region opens.

---

## P0 — Chip baseline (DONE 2026-08-18)

All green (`failures: 0`, `checksum_ok: true`, `--seed 42`). Use **c=1** `duration_ms` for chip.

| Pack | `--n` | median `duration_ms` | create ≈ | Files |
| --- | --- | --- | --- | --- |
| media | 40 | **15.3 s** (1 pass) | ~0.38 s | `data/media/docker/concurrency_20260818_183208_n40.jsonl` |
| evals | 3 | **5.30 s** (2×) | ~0.39 s | `…/evals/docker/…_183107_n3.jsonl`, `…_183155_n3.jsonl` |
| analytics | 200 | **3.17 s** (2×) | ~1.07 s | `…/analytics/docker/…_183023_n200.jsonl`, `…_183123_n200.jsonl` |
| rl | 5000 | **2.67 s** @ c=1 | ~0.91 s | `data/rl/docker/concurrency_20260818_175645_n5000.jsonl` (also has c=88) |
| disk | 512 | **1.98 s** (2×) | ~0.38 s | `…/disk/docker/…_183039_n512.jsonl`, `…_183134_n512.jsonl` |
| agent | 100 | **1.98 s** (2×) | ~1.23 s | `…/agent/docker/…_183048_n100.jsonl`, `…_183147_n100.jsonl` |

Also on disk (density / smoke — keep, don’t redo unless P3): `rl --n 64` ladders, light smokes under `data/*/docker/concurrency_20260818_*`.

---

## P1 — Chip depth (run next)

Strengthen weak signals + more repeats for stable medians. Still **`--levels 1`**.

```bash
# agent: bump n so duration ≫ create (~1.2s tax at n=100)
uv run main.py --benchmark agent --runner docker --levels 1 --n 200 --seed 42
uv run main.py --benchmark agent --runner docker --levels 1 --n 200 --seed 42
uv run main.py --benchmark agent --runner docker --levels 1 --n 200 --seed 42
```

```bash
# media: only 1 pass so far — get to 3
uv run main.py --benchmark media --runner docker --levels 1 --n 40 --seed 42
uv run main.py --benchmark media --runner docker --levels 1 --n 40 --seed 42
```

```bash
# bring every pack to ≥3 chip passes @ headline n
uv run main.py --benchmark analytics --runner docker --levels 1 --n 200 --seed 42
uv run main.py --benchmark disk --runner docker --levels 1 --n 512 --seed 42
uv run main.py --benchmark evals --runner docker --levels 1 --n 3 --seed 42
uv run main.py --benchmark rl --runner docker --levels 1 --n 5000 --seed 42
uv run main.py --benchmark rl --runner docker --levels 1 --n 5000 --seed 42
```

**Pass check:** `failures: 0`, `checksum_ok: true`, `p50_duration_ms` multi-second and > create tax.

---

## P2 — Heavy concurrency ladders (chip under load)

Same heavy `--n` as chip, full ladder. Under contention, watch **`duration_ms`** rise (silicon/queue stress) — not just wall create.

```bash
uv run main.py --benchmark rl --runner docker --levels 1 8 22 44 88 --n 5000 --seed 42
```

```bash
uv run main.py --benchmark analytics --runner docker --levels 1 8 22 44 88 --n 200 --seed 42
```

```bash
uv run main.py --benchmark evals --runner docker --levels 1 8 22 44 88 --n 3 --seed 42
```

```bash
uv run main.py --benchmark agent --runner docker --levels 1 8 22 44 88 --n 200 --seed 42
```

```bash
uv run main.py --benchmark disk --runner docker --levels 1 8 22 44 88 --n 512 --seed 42
```

```bash
# slowest — run if time; else shorten to --levels 1 22 88
uv run main.py --benchmark media --runner docker --levels 1 8 22 44 88 --n 40 --seed 42
```

If a level OOMs / flaky: note it, drop to `--levels 1 8 22 44` and continue. Don’t abandon the whole pack.

**Optional second heavy ladder** (great for EDA if hours remain): re-run the same six commands once more.

---

## P3 — Density ladders (packing / Chart B)

Light `--n` so create/schedule dominates. Useful for “how many Docker sandboxes on this Vera host,” **not** chip slides.

```bash
uv run main.py --benchmark rl --runner docker --levels 1 8 22 44 88 --n 64 --seed 42
```

```bash
uv run main.py --benchmark agent --runner docker --levels 1 8 22 44 88 --n 20 --seed 42
```

```bash
uv run main.py --benchmark evals --runner docker --levels 1 8 22 44 88 --n 1 --seed 42
```

```bash
uv run main.py --benchmark analytics --runner docker --levels 1 8 22 44 88 --n 10 --seed 42
```

```bash
uv run main.py --benchmark disk --runner docker --levels 1 8 22 44 88 --n 128 --seed 42
```

```bash
# media density is still multi-second work — optional / last
uv run main.py --benchmark media --runner docker --levels 1 8 22 44 88 --n 10 --seed 42
```

Push higher if the host is happy (352 CPUs):

```bash
uv run main.py --benchmark rl --runner docker --levels 1 8 22 44 88 176 --n 64 --seed 42
```

```bash
uv run main.py --benchmark agent --runner docker --levels 1 8 22 44 88 176 --n 20 --seed 42
```

---

## P4 — n-sweeps + alt seeds (fill remaining time)

### n-sweep @ c=1 (scaling curves)

```bash
for n in 50 100 200 400; do
  uv run main.py --benchmark analytics --runner docker --levels 1 --n $n --seed 42
done
```

```bash
for n in 128 256 512 1024; do
  uv run main.py --benchmark disk --runner docker --levels 1 --n $n --seed 42
done
```

```bash
for n in 50 100 200 400; do
  uv run main.py --benchmark agent --runner docker --levels 1 --n $n --seed 42
done
```

```bash
for n in 1 2 3 5; do
  uv run main.py --benchmark evals --runner docker --levels 1 --n $n --seed 42
done
```

```bash
for n in 10 20 40 60; do
  uv run main.py --benchmark media --runner docker --levels 1 --n $n --seed 42
done
```

```bash
for n in 1000 3000 5000 10000; do
  uv run main.py --benchmark rl --runner docker --levels 1 --n $n --seed 42
done
```

### Alt seeds (robustness at headline chip n)

```bash
for seed in 43 44 45; do
  uv run main.py --benchmark analytics --runner docker --levels 1 --n 200 --seed $seed
  uv run main.py --benchmark disk --runner docker --levels 1 --n 512 --seed $seed
  uv run main.py --benchmark agent --runner docker --levels 1 --n 200 --seed $seed
  uv run main.py --benchmark evals --runner docker --levels 1 --n 3 --seed $seed
  uv run main.py --benchmark media --runner docker --levels 1 --n 40 --seed $seed
  uv run main.py --benchmark rl --runner docker --levels 1 --n 5000 --seed $seed
done
```

---

## Clean / usable data (Vera Docker — audited)

**Keep for analysis** (all `failures: 0`, `--seed 42`, `arch=aarch64`, `cpu_count=352`):

| Set | Rule | Status |
| --- | --- | --- |
| **Chip @ c=1** | Headline `--n` only; prefer **agent n=200** (not n=100) | 17 green passes |
| **Heavy ladders** | Same headline `--n`, levels `1 8 22 44 88` | 6 green (one per pack) |
| **Density ladders** | Light `--n`, prefer files that include **88** (and 176 where present) | 9 green; prefer newest per pack |

**Exclude / don’t compare**

- Early smokes (`analytics n=5`, `disk n=1`, `media n=1`, `agent n=20` @ c=1 only)
- Failed early RL density: `…_174319_n64.jsonl`, `…_174426_n64.jsonl` (`failures: 1`)
- Agent chip **n=100** — superseded by n=200 for x86 mirror
- Mixing P3 light-`n` into chip slides

S3 snapshot already has the full tree; analysis just needs to **filter** to the rows above.

---

## Apples-to-apples vs x86 (core-count reality)

Vera reports **`cpu_count=352`**. You will rarely get a matching x86 box. That does **not** block a fair chip story — it changes **which charts** are fair.

### Tier A — silicon / workload speed (primary GTM) — **no 300+ cores needed**

Compare **`duration_ms` @ concurrency 1** only.

| Match | Why |
| --- | --- |
| Same `--benchmark`, `--n`, `--seed 42`, `--runner docker` | Same work |
| Same (or noted) image / git SHA | Same code |
| Judge **`p50_duration_ms`** (median of ≥2–3 passes) | Not wall `latency_ms` |

A **16–64 core** x86 host is fine: one container does not need 352 cores. This is the apples-to-apples chip claim.

**x86 minimum (do this first):**

```bash
uv run main.py --benchmark analytics --runner docker --levels 1 --n 200 --seed 42
uv run main.py --benchmark disk --runner docker --levels 1 --n 512 --seed 42
uv run main.py --benchmark agent --runner docker --levels 1 --n 200 --seed 42
uv run main.py --benchmark evals --runner docker --levels 1 --n 3 --seed 42
uv run main.py --benchmark media --runner docker --levels 1 --n 40 --seed 42
uv run main.py --benchmark rl --runner docker --levels 1 --n 5000 --seed 42
# repeat each 2–3×
```

Record `meta.env.cpu_count` / `cpu_model` on the x86 side for the footnote.

### Tier B — concurrency / density @ **32-core parity** (use this)

Each Docker worker already gets `--cpus=1`. On unrestricted Vera (352 cores), c=88 barely contends. On a **32-core x86**, c=88 oversubscribes.

**Fix:** pin Vera (and later x86) with `--host-cpus 32` → Docker `--cpuset-cpus=0-31`. Results land in `data/<bench>/docker-c32/` (separate from full-machine `docker/`).

Same levels / `--n` / `--seed` on both hosts → fair oversubscription compare.

#### Vera now — heavy ladders (32-core cap)

```bash
uv run main.py --benchmark rl --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 5000 --seed 42
uv run main.py --benchmark analytics --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 200 --seed 42
uv run main.py --benchmark evals --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 3 --seed 42
uv run main.py --benchmark agent --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 200 --seed 42
uv run main.py --benchmark disk --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 512 --seed 42
uv run main.py --benchmark media --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 40 --seed 42
```

#### Vera now — density ladders (32-core cap)

```bash
uv run main.py --benchmark rl --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 64 --seed 42
uv run main.py --benchmark agent --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 20 --seed 42
uv run main.py --benchmark evals --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 1 --seed 42
uv run main.py --benchmark analytics --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 10 --seed 42
uv run main.py --benchmark disk --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 128 --seed 42
uv run main.py --benchmark media --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 10 --seed 42
```

**Pass check:** `meta.host_cpus=32`, `meta.docker_cpuset_cpus=0-31`, path contains `docker-c32`, `failures: 0`.

#### Later x86 (32-core machine) — mirror exactly

```bash
# same flags; --host-cpus 32 keeps cpuset identical even if the box has SMT quirks
uv run main.py --benchmark rl --runner docker --host-cpus 32 --levels 1 8 22 44 88 --n 5000 --seed 42
# … same list as Vera heavy + density above
```

**Still unfair without disclosure:** disk @88 (FS + storage differ). Prefer disk @ c=1 for chip; treat disk ladder as infra.

### Tier C — product density (Daytona)

Single-host Docker ceiling is **not** the multi-runner product story. After onsite, density vs region belongs in Daytona (`onsite-vera-gtc-runbook.md`).

---

## Extra Vera time

1. **Tier B `--host-cpus 32` heavy + density** (above) — highest value now that x86 is 32 cores  
2. More **chip @ c=1** repeats / alt seeds (Tier A; no `--host-cpus` needed)  
3. Keep full-machine `docker/` P2/P3 as “Vera at full width” story — do **not** mix with `docker-c32` in the same chart without labeling

---

## EDA

```bash
uv run python scripts/eda_vera_docker.py
uv run python eda.py --benchmark rl   # will pick up docker-c32 series when present
```

---

## Read guide

| Question | Fair compare | Not fair |
| --- | --- | --- |
| Is Vera faster on our workloads? | `duration_ms` @ **c=1**, matched `--n`/`--seed` | wall latency |
| Concurrency under **32-core parity**? | `docker-c32` vs x86 `--host-cpus 32`, same levels | full `docker/` @88 vs small x86 |
| Vera full-width packing? | unrestricted `docker/` P2/P3 (Vera-only) | unlabeled vs 32-core x86 |
| Disk under load? | c=1 chip; or same-cap ladder with FS caveat | ignoring storage differences |

**Don’t** burn Vera time on slides while the node is yours — run Tier B `--host-cpus 32` next.

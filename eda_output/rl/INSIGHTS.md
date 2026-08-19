# RL concurrency insights (chip ladder)

Same params across series:

```text
--benchmark rl --levels 1 8 22 44 88 --n 5000 --seed 42 -E 8
```

Charts: `eda_output/rl/` (generated with `--exclude docker,rlp-arm64`).

## Headline numbers

| series | c=1 p50 duration | c=88 throughput |
| --- | ---: | ---: |
| daytona (EPYC container) | 4978 ms | 14.5 /s |
| daytona-graviton5 (linux-vm cold) | 1084 ms | 37.8 /s |
| daytona-graviton5-hot (linux-vm hot) | 1089 ms | 35.5 /s |
| rlp-x86 | 709 ms | 13.1 /s |
| **rlp-vera** | **672 ms** | **45.3 /s** |

- **Chart A (chip):** `duration_ms` — in-sandbox work only. Lower is better.
- **Chart B (density):** throughput at high concurrency. Higher is better.
- Graviton5 was run as **linux-vm** (that target has no container runners); Daytona x86 was **container**. Treat that as a soft caveat when comparing those two.

## What `duration_ms` measures (chip only)

`duration_ms` is timed **inside** the sandbox (`time.perf_counter()` around the RL episode only). It does **not** include network, sandbox create, or delete.

- **`latency_ms`** = harness wall (create+first exec on cold; exec-only on warm).
- Warm **latency − duration** is ~100–400 ms of toolbox/exec overhead — not in `duration_ms`.
- All compared series share the **same checksum** for `(n=5000, seed=42)` → same work.

Use **`duration_ms` for chip claims**; do not use `latency_ms`.

## Uniform 1 vCPU (the important toggle)

Every cloud series in this pack **requests / bakes 1 vCPU**:

| runner | How 1 vCPU is set |
| --- | --- |
| rlp-x86 / rlp-vera | Every create: `Resources(cpu=1, …)` |
| daytona (EPYC) | Snapshot `vera-rl-benchmark` baked at **cpu=1** (create-from-snap cannot override) |
| daytona-graviton5 / hot | Snaps baked at **cpu=1** |

Do **not** confuse that with the env probe’s `os.cpu_count()` (often 16 / 48 / 2 / 1). That is **host topology visibility**, not “we got N vCPUs.” The quota we set is **1**.

So rlp-x86 at ~710 ms next to Vera at ~670 ms is still under a **1 vCPU request** — likely EPYC single-thread strength on this NumPy GEMM mix, not a multi-vCPU misconfig. Graviton5 at ~1080 ms is also 1 vCPU.

## Three simple claims

### 1. GTM

On the RL chip workload, Vera finishes episodes in **~0.7s** vs **~5.0s** on Daytona’s x86 path (**~7× faster**), and at high concurrency it delivers **~45 jobs/s** vs **~14** on Daytona (**~3× more throughput**).

### 2. CEO

Vera is the density winner in this pack: **highest packing rate** (45.3/s at c=88) while keeping per-episode work flat (~672–684 ms across the ladder)—the profile you want for more agent rollouts per dollar of infra.

### 3. CTO

Chip metric (`duration_ms`) puts Vera and RLP x86 in the same ballpark (672 vs 709 ms) under uniform 1 vCPU. The gap opens on scale: Vera holds duration flat and scales to **45/s**, while RLP x86 stalls near **13/s** and Graviton5 lands in between (**~38/s**, ~1.6× slower chip than Vera).

## Why duration moves with concurrency

Two different effects — don’t read both as “chip got faster/slower.”

**rlp-x86 — duration goes up (real contention).**  
As concurrency rises, sandboxes pack onto shared x86 hosts and each episode’s CPU time stretches (p50 ~709 ms at c=1 → ~1520 ms at c=44; at c=88 the mean blows out on a long tail while throughput stalls ~13–14/s). Classic noisy-neighbor / oversubscription. Vera stays flat (~670 ms) on the same ladder.

**daytona — mean duration “goes down” (~4500 → ~3666) — mostly a small-sample quirk.**  
c=1 is only **8 episodes on 1 sandbox**; that one box ran slow (mean ~4590 ms). From c=8 onward you’re averaging dozens–hundreds of episodes and the distribution settles ~3600–3800 ms. That is **not** “more concurrency makes the chip faster.” (On that c=1 sandbox the cold episode was actually *faster* than later warm ones, so it isn’t cold-start inflation either.)

**How to read the charts:** trust flat/high-c curves for chip claims (Vera; Graviton5’s mild rise); treat Daytona c=1 mean duration as under-powered; treat rlp-x86’s climb as capacity contention — which is why Vera’s density story is the stronger one.

## Source files (newest per series)

| series | file |
| --- | --- |
| daytona | `data/rl/daytona/concurrency_20260818_235516_n5000.jsonl` |
| daytona-graviton5 | `data/rl/daytona-graviton5/concurrency_20260819_181203_n5000.jsonl` |
| daytona-graviton5-hot | `data/rl/daytona-graviton5-hot/concurrency_20260819_182658_n5000.jsonl` |
| rlp-x86 | `data/rl/rlp-x86/concurrency_20260819_181152_n5000.jsonl` |
| rlp-vera | `data/rl/rlp-vera/concurrency_20260818_234200_n5000.jsonl` |

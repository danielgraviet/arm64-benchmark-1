# Disk concurrency insights (sandbox FS ladder)

Same params across the headline series (high-c extension of the original ladder):

```text
--benchmark disk --levels 1 8 22 44 88 176 352 --n 128 --seed 42 -E 1
```

`-E 1` is intentional: fresh sandbox per episode so the probe is density + FS, not warm reuse of the same temp dir.

Charts: `eda_output/disk/` (generated with `--exclude docker,daytona,daytona-vm,daytona-vm-hot`; `rlp-x86` is the Aug 13 file and only goes through c=88).

## Headline numbers

| series | c=1 p50 duration | c=88 p50 duration | c=88 tput | c=352 p50 duration | c=352 tput |
| --- | ---: | ---: | ---: | ---: | ---: |
| **rlp-vera** | **426 ms** | **433 ms** | **34.2 /s** | **436 ms** | **19.5 /s** |
| daytona-graviton5 (linux-vm cold) | 523 ms | 3574 ms | 5.4 /s | 10665 ms | 12.3 /s |
| daytona-graviton5-hot (linux-vm hot) | 774 ms | 9027 ms | 6.1 /s | 40265 ms | 3.9 /s |
| rlp-x86 (older; no 176/352) | 851 ms | 889 ms | 14.7 /s | — | — |

- **Chip / FS work:** `duration_ms` — sequential write/fsync/read + small-file storm inside the sandbox. Lower is better.
- **Density:** throughput at high concurrency. Higher is better.
- Same checksum for `(n=128, seed=42)` on Vera / G5 / G5-hot → same work.
- Workload peak is ~160 MiB; G5 snaps have **3 GiB** disk — storage size is not the limiter.
- G5 cold c=352 had **92 failures**; G5 hot had 1 failure at c=176 and c=352. Vera retry: **0 failures** through c=352.

## What this pack measures

`sandbox-disk-v1`: `n` MiB sequential write + fsync + read, plus `n×64` small files (1–4 KiB). Timed inside the sandbox only (`duration_ms`). Create/network sit in `latency_ms`.

This is an **eng / infra FS axis**, not Vera BW/core marketing. Still useful as a packing story: can the platform keep per-job FS time flat while concurrency climbs?

## Three simple claims

### 1. GTM

On sandbox disk I/O, Vera holds **~430 ms** per job from c=1 through c=352 and packs **~34 jobs/s** at c=88. Graviton5 cold starts in the same ballpark at c=1 (~523 ms) but stretches to **~3.6 s** at c=88 (~5/s) and **~10.7 s** at c=352.

### 2. CEO

Vera is the density winner here: **flat chip time** + **~6× the Graviton5 throughput** at c=88. Hot memory snaps do **not** help this pack — they make duration worse under load.

### 3. CTO

At c=1, Vera and G5 cold are close (426 vs 523 ms). The gap is **contention under concurrency**: G5 duration climbs ~20× (523 → 10665 ms) while Vera stays flat (~426–436 ms). Hot snaps start slower (774 ms) and degrade further (40 s at c=352) — memory restore is the wrong lever for a cold-create density ladder (`-E 1`).

## Why Vera throughput peaks at c=88 (then drops at 176 / 352)

This is **create/schedule tax**, not the disk probe falling over.

Throughput is `jobs / wall_time` of a barrier wave (C threads start together; the clock stops when the last job finishes). Wave time ≈ **max `latency_ms`**. Chip time (`duration_ms`) stays ~426–437 ms at every level — including c=352.

| c | p50 duration | p50 wall | p99 wall | create tax p50 → p99 | throughput |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 88 | 433 ms | 1.7 s | 2.5 s | 1.3 s → 2.1 s | **34.2 /s** |
| 176 | 437 ms | 2.3 s | 5.4 s | 1.8 s → 5.0 s | **31.7 /s** |
| 352 | 436 ms | 9.1 s | 17.8 s | 8.6 s → 17.4 s | **19.5 /s** |

If median wall had kept scaling, c=176 would be ~78/s. Measured 31.7/s is **176 / max wall (~5.5 s)**. Same at 352: **352 / ~18 s ≈ 19.5/s**. Wall histograms are queued, not uniformly slower: at c=176 a fast group finishes in 0–2 s then ~56 jobs sit in the 5 s bucket; at c=352 a pile around 9 s and ~38 jobs at ~17 s.

**Do not compare this to RL’s 63.89 /s at c=352.** That RL ladder is `-E 8`: 352 sandboxes × 8 episodes = **2816 jobs**. Create is paid once; the other seven are warm execs. Numerator is 8×; median wall stays ~1 s because most rows are warm. Disk is `-E 1`: 352 creates = **352 jobs**, every row pays full create. Same cell, same 352 creates; RL then keeps scoring episodes. Disk cannot.

The first Vera disk c=352 wave was a **broken pipe** (352 failures, ~11 ms walls — client/tunnel, not chip). The retry (`20260819_202521`) already succeeded with 0 failures and still showed the queued wall. Another disk pass might shave tail if the cell/tunnel is quieter; it will not turn `-E 1` disk into RL-shaped throughput. Switching disk to `-E 8` would reuse the sandbox FS and stop being this cold-create density test.

## Why duration moves with concurrency

**rlp-vera — flat.** Per-job FS time stays ~420–440 ms through c=352; wall latency rises with create/schedule tax, but chip work does not. Throughput peaks at c=88 (~34/s), then the create queue stretches the wave.

**rlp-x86 — also flat chip, lower packing (ladder only to c=88).** Duration ~851–889 ms; throughput ~14.7/s at c=88. Older file; no 176/352.

**daytona-graviton5 cold — classic FS/noisy-neighbor climb.** Duration ~523 → 835 → 1185 → 1748 → 3574 → 5620 → 10665 ms as concurrency rises. Throughput plateaus ~5–8/s through c=176; c=352 tput 12.3/s is mixed with **92 failures** — do not treat that point as a clean density win.

**daytona-graviton5-hot — worse, not better.** At `-E 1` every job is a fresh sandbox, so “hot” memory state does not amortize create the way a warm `-E 8` chip ladder might. Observed duration is **higher** than cold at every level (774 → 40265 ms); treat hot as a boot experiment, not a disk-chip win.

## Caveats

- G5 path is **linux-vm** on `us-east-1-arm`; Vera is RLP dedicated cell + Hub image. Soft compare across products.
- G5 disk snaps inherited the shared seed’s **mem=1 GiB** (disk pack’s `docker_memory` is 2 GiB). Unlikely to drive the n=128 FS climb, but not a perfect RAM pin match.
- Older `daytona-vm` / `daytona-vm-hot` / `docker` series under `data/disk/` are prior runs (different targets/params) — excluded from the charts above.
- Harness throughput counts completed records over the wave, including failures. G5 cold c=352’s 12.3/s is not comparable to Vera’s 0-failure 19.5/s.

## Source files (this compare)

| series | file |
| --- | --- |
| rlp-vera | `data/disk/rlp-vera/concurrency_20260819_202521_n128.jsonl` (retry after broken-pipe c=352) |
| daytona-graviton5 | `data/disk/daytona-graviton5/concurrency_20260819_202058_n128.jsonl` |
| daytona-graviton5-hot | `data/disk/daytona-graviton5-hot/concurrency_20260819_202332_n128.jsonl` |
| rlp-x86 | `data/disk/rlp-x86/concurrency_20260813_194536_n128.jsonl` (c=1…88 only) |

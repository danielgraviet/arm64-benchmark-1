# Media concurrency insights (FFmpeg / Chart C)

Same params on Vera and Graviton5 cold:

```text
--benchmark media --levels 1 8 22 44 88 176 --n 40 --seed 42 -E 8
```

Each sandbox is **2 GiB**. `-E 8` = create once, encode 8 times, delete. `--n 40` = 3600 frames (640×360, piped to FFmpeg — not a raw dump on disk).

Charts: `eda_output/media/` (`--exclude docker,daytona,daytona-vm,daytona-vm-hot,rlp-x86,e2b,rlp-arm64`).

## Headline numbers

| series | c=1 p50 duration | c=88 p50 duration / tput | c=176 p50 duration / tput | fails |
| --- | ---: | ---: | ---: | ---: |
| **rlp-vera** | **15.3 s** | **16.2 s / 5.0 /s** | **16.7 s / 5.6 /s** | **52 at 176** |
| daytona-graviton5 (linux-vm cold) | 18.0 s | 19.1 s / 4.4 /s | 20.9 s / 4.3 /s | **0** |

- **Chip / BW:** `duration_ms` — generate frames + h.264 encode + decode-verify. Lower is better.
- **Density:** throughput (episodes / wave wall). Higher is better.
- Same checksum through **c=88**. Vera c=176 checksum is false because of the 52 fails.

## What this pack measures

`media-transcode-v1` at `n=40`: Chart C bandwidth sibling to analytics (DuckDB). Timed **inside** the sandbox only. Jobs are **~15–21 s**, so throughput will look small next to agent (~25/s) or RL — that is episode length, not a broken ladder.

## Three simple claims

### 1. GTM

On FFmpeg transcode, Vera finishes a job in **~15 s** idle vs **~18 s** on Graviton5 (~15% faster), and at 88 concurrent sandboxes it packs **~5 jobs/s** vs **~4.4/s**. Same encode, slightly more completed work. Do not quote Vera’s 5.6/s at 176.

### 2. CEO

Vera is the **better encode box** (~15% faster chip, duration stays ~15–17 s). This is **not** an agent-style density blowout: long jobs mean 88 boxes only yield ~5 vs ~4.4 encodes/s. Sell **faster media preprocess at 88**, not “2× packing.” Drop Vera c=176 from the slide (**52 failures**).

### 3. CTO

Idle gap is real encode/BW (15.3 vs 18.0 s) under 1 vCPU / 2 GiB. Both hold duration under pack: Vera **+9%** to c=176, G5 **+16%**. Contrast with **agent**, where G5 stretched ~3.7× — FFmpeg here does not show that collapse. Vera c=176 tput is **not** a scale win: 52 create/boot fails + p99 wall ~64 s; G5 at 176 is slower per job but **0 fails**. Wave time at c=88 is mostly **8 × ~16–19 s chip**, so create tax is a small fraction until the queue/fail tail.

## Why throughput stays ~5/s (and why 176 is messy)

Throughput is **704 or 1408 episodes / wall until the last sandbox finishes all 8**. One encode is already ~15–19 s, so 8 sequential runs are ~2–2.5 minutes even with a fast create.

| c | p50 duration | p50 wall | p99 wall | tput | fails |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 88 | 16.2 s | 16.3 s | 25.5 s | **5.0 /s** | 0 |
| 176 | 16.7 s | 16.7 s | **64.1 s** | 5.6 /s | **52** |

At c=88, 704 / ~142 s ≈ 5/s. G5 is 704 / ~160 s ≈ 4.4/s because chip is ~19 s, not because packing failed.

Do **not** treat Vera 5.6/s at 176 as beating G5 4.3/s. Harness tput counts completed records on a wave that also dropped 52 jobs.

## Why duration moves with concurrency

**rlp-vera — flat encode.** 15.3 → 16.2 → 16.7 s. Neighbor tax is small. Failures at 176 are boot/create, not FFmpeg getting slower.

**daytona-graviton5 — mild stretch, no fails.** 18.0 → 19.1 → 20.9 s. Reliable at 176; still ~3–4 s slower than Vera at every level.

## Caveats

- Soft compare: Vera is RLP dedicated cell + Hub image; G5 is linux-vm on `us-east-1-arm`.
- G5 snap is **2 GiB** (`vera-media-benchmark-us-east-1-arm`, seed `…-m2`).
- No graviton5-hot media snap in this compare.
- Chart C sibling: analytics (DuckDB) already has a cleaner 176 story; use media for **encode chip**, agent for **density**.
- Vera smoke (`n=1`) was ~907 ms; this ladder is `n=40` (~15 s). Do not mix those durations.

## Source files

| series | file |
| --- | --- |
| rlp-vera | `data/media/rlp-vera/concurrency_20260819_224229_n40.jsonl` |
| daytona-graviton5 | `data/media/daytona-graviton5/concurrency_20260819_224525_n40.jsonl` |

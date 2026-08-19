# Analytics concurrency insights (DuckDB / mem-BW)

Same params on Vera and Graviton5 cold (ladder capped at 176 — see below):

```text
--benchmark analytics --levels 1 8 22 44 88 176 --n 200 --seed 42 -E 8
```

Each sandbox is **4 GiB**. `-E 8` = create once, run the pipeline 8 times, delete.

Charts: `eda_output/analytics/` (`--exclude docker,daytona,daytona-vm,daytona-vm-hot,rlp-x86,e2b,rlp-arm64`). Phoenix evals/analytics did not boot (NFS snapshot missing); ignore `rlp-x86` for this pack.

## Headline numbers

| series | c=1 p50 duration | c=88 p50 duration / tput | c=176 p50 duration / tput | fails |
| --- | ---: | ---: | ---: | ---: |
| **rlp-vera** | **3356 ms** | **3916 ms / 18.3 /s** | **4088 ms / 14.4 /s** | **0** |
| daytona-graviton5 (linux-vm cold) | 4078 ms | 5214 ms / 12.3 /s | 5886 ms / 14.3 /s | 1 at c=22 |

- **Chip / BW:** `duration_ms` — generate Parquet + DuckDB scan/join/agg inside the sandbox. Lower is better.
- **Density:** throughput (episodes / wave wall). Higher is better.
- Same checksum for `(n=200, seed=42)` on both series → same work.
- Vera file is the **zero-fail retry**. G5 still has one stray fail at c=22; c=176 was clean.

## What this pack measures

`analytics-parquet-v1` at `n=200`: ~400k customers / ~2M orders / ~6M line items. Timed **inside** the sandbox only. Create and toolbox sit in `latency_ms`. This is Chart C (memory bandwidth), not a coding-agent chip pack.

## Three simple claims

### 1. GTM

On DuckDB analytics, Vera finishes a query in **~3.4 s** idle vs **~4.1 s** on Graviton5, and packs **~18 queries/s** at 88 concurrent sandboxes vs **~12/s** on G5. That is the slide: faster per job, more jobs at the operating point.

### 2. CEO

Vera is the **better analytics box** (about **18% faster** at c=1, still **~25% faster** at c=88) and the **better packer up to 88**. Pushing to 176 does **not** buy more completed work on Vera — throughput falls back to ~14/s, even with zero failures. Sell **88 × 4 GiB**, not “max concurrency.”

### 3. CTO

Idle gap is real chip/BW (3356 vs 4078 ms) under 1 vCPU / 4 GiB. Vera duration only stretches **~22%** to c=176; G5 stretches **~44%**. Vera’s c=176 throughput drop is **create/schedule queue** (p99 wall ~68 s vs chip ~4.1 s), not DuckDB falling over. G5 still climbing at 176 is the same wave-length effect with slower chip: both waves take ~100 s, so tput ties (~14.4 vs 14.3/s). Daytona org RAM cap is **1000 GiB** — 352 × 4 GiB cannot run; do not “fix” that by shrinking `--n`.

## Why Vera throughput peaks at c=88

Throughput is **1408 (or 704) episodes / wall until the last sandbox finishes all 8**. Chip time stays ~3.4–4.1 s. Wave time is create wait + **8 sequential DuckDB runs**.

| c | p50 duration | p50 wall | p99 wall | tput |
| ---: | ---: | ---: | ---: | ---: |
| 88 | 3916 ms | 4.1 s | 7.1 s | **18.3 /s** |
| 176 | 4088 ms | 4.3 s | **67.7 s** | **14.4 /s** |

At c=88, 704 / ~38 s ≈ 18/s (8 × ~4 s chip + modest create). At c=176 a tail of boxes wait ~1 minute to boot, then still owe 7 warm runs — wall ~100 s, so 1408 / ~100 s ≈ 14/s. More sandboxes, longer queue, **fewer completed queries per second**.

G5 at c=176 matches that ~14/s because **its chip is slower** (~5.9 s), so the wave is long even without Vera’s 68 s create tail.

## Why duration moves with concurrency

**rlp-vera — mild BW neighbor tax, then flat-ish.** 3356 → 3916 → 4088 ms. DuckDB is memory-bandwidth heavy, so a little stretch under pack is expected. Not a collapse.

**daytona-graviton5 — more stretch.** 4078 → 5214 → 5886 ms. Same workload, more noisy-neighbor / mem-BW contention on the linux-vm path. One fail at c=22; ignore that point for checksum, keep the rest.

## Caveats

- Soft compare: Vera is RLP dedicated cell + Hub image; G5 is linux-vm on `us-east-1-arm`.
- G5 analytics snap is **4 GiB** (`…-m4` seed). Earlier `214810` was a **1 GiB** OOM — do not chart it.
- c=352 is off this ladder: Daytona **1000 GiB** org limit (352 × 4 GiB = 1408 GiB).
- Phoenix (`us-phoenix-1`) analytics/evals: snapshot name resolves, **NFS manifest missing** — not a chip result.
- No graviton5-hot analytics snap in this compare.

## Source files

| series | file |
| --- | --- |
| rlp-vera | `data/analytics/rlp-vera/concurrency_20260819_222014_n200.jsonl` (0 fails) |
| daytona-graviton5 | `data/analytics/daytona-graviton5/concurrency_20260819_221113_n200.jsonl` |

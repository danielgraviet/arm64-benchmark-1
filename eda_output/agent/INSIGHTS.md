# Agent concurrency insights (repo-agent chip)

Same params on Vera and Graviton5 cold:

```text
--benchmark agent --levels 1 8 22 44 88 176 --n 200 --seed 42 -E 8
```

Each sandbox is **1 GiB**. `-E 8` = create once, run the agent 8 times, delete.

Charts: `eda_output/agent/` (`--exclude docker,daytona,daytona-vm,daytona-vm-hot,rlp-x86,e2b,rlp-arm64`).

## Headline numbers

| series | c=1 p50 duration | c=88 p50 duration / tput | c=176 p50 duration / tput | fails |
| --- | ---: | ---: | ---: | ---: |
| **rlp-vera** | **2454 ms** | **2794 ms / 24.7 /s** | **3023 ms / 16.5 /s** | **0** |
| daytona-graviton5 (linux-vm cold) | 2897 ms | 7127 ms / 11.1 /s | 10804 ms / 13.3 /s | **0** |

- **Chip:** `duration_ms` — search / AST / edit / pytest / SQL inside the sandbox. Lower is better.
- **Density:** throughput (episodes / wave wall). Higher is better.
- Same checksum for `(n=200, seed=42)` on both series → same work.

## What this pack measures

`repo-agent-v2` at `n=200`: coding-agent-shaped CPU in an isolated tmp workspace. Timed **inside** the sandbox only. Create and toolbox sit in `latency_ms`. This is the **product** Chart A pack (not DuckDB, not evals).

## Three simple claims

### 1. GTM

On the coding-agent workload, Vera finishes a job in **~2.5 s** idle vs **~2.9 s** on Graviton5. At 88 concurrent sandboxes it is **~2.8 s** vs **~7.1 s**, and packs **~25 jobs/s** vs **~11/s**. That is the customer slide: same agent, more completed work.

### 2. CEO

Vera is the density winner here: **~2.2× the Graviton5 throughput** at 88 boxes, with per-job time almost flat. Graviton5 gets **slower as you add tenants** (~2.9 s → 7.1 s → 10.8 s). Sell **88 concurrent agents** on Vera. 176 does not increase Vera’s completed-job rate (24.7/s → 16.5/s).

### 3. CTO

Idle gap is modest (2454 vs 2897 ms) under 1 vCPU / 1 GiB. The gap is **contention**: Vera duration only stretches **~23%** to c=176; G5 stretches **~3.7×** (2897 → 10804 ms). Vera’s c=176 tput drop is **create/schedule queue** (p99 wall ~37 s vs chip ~3.0 s). G5’s wave is long because **chip time itself blew up** (~8 × 10.8 s), so tput still “climbs” a bit at 176 while each tenant is worse.

## Why Vera throughput peaks at c=88

Throughput is **704 or 1408 episodes / wall until the last sandbox finishes all 8**. Chip time stays ~2.5–3.0 s. Wave time is create wait + **8 sequential agent runs**.

| c | p50 duration | p50 wall | p99 wall | tput |
| ---: | ---: | ---: | ---: | ---: |
| 88 | 2794 ms | 3.0 s | 6.1 s | **24.7 /s** |
| 176 | 3023 ms | 3.3 s | **37.0 s** | **16.5 /s** |

At c=88, 704 / ~28 s ≈ 25/s. At c=176 a tail of boxes wait tens of seconds to boot, then still owe 7 warm runs — fewer completed jobs per second even with zero failures.

G5 at c=88 is already ~11/s because **duration is 7.1 s**, not because of a 37 s create tail.

## Why duration moves with concurrency

**rlp-vera — holds.** 2454 → 2794 → 3023 ms. Mild neighbor tax; the agent still looks like the idle chip.

**daytona-graviton5 — noisy-neighbor climb.** 2897 → 3365 → 3995 → 7127 → 10804 ms. Same `n=200` work; linux-vm packing stretches CPU/FS time. Do not read the 13.3/s at c=176 as “G5 scaled better” — each job is **~3.7× slower** than idle.

## Caveats

- Soft compare: Vera is RLP dedicated cell + Hub image; G5 is linux-vm on `us-east-1-arm`.
- G5 snap is **1 GiB** (`vera-agent-benchmark-us-east-1-arm`, seed `…-m1`).
- No graviton5-hot agent snap in this compare.
- This is **`-E 8` chip**, not Chart B density (`n=20 -E 1` not run).

## Source files

| series | file |
| --- | --- |
| rlp-vera | `data/agent/rlp-vera/concurrency_20260819_223148_n200.jsonl` |
| daytona-graviton5 | `data/agent/daytona-graviton5/concurrency_20260819_223305_n200.jsonl` |

# Sep 1 meeting. Vera vs Zen 5 (9J45), and what was wrong with the old numbers

August–September 2026. Same workload, same seed. Matched concurrency rungs **44** through **2,000**.

This is the same agent ladder as [`nvidia-agent-brief-maxpack.md`](nvidia-agent-brief-maxpack.md), with the measurement story NVIDIA asked for.

## What was off before, and why these numbers are the ones to use

We published earlier Zen 5 curves that understated packing. Two separate mistakes. Neither was Vera.

**9575 looked weak because we only had one socket.** That SKU is a high-frequency Zen 5. The box we could get in time was **one socket** (64 cores / 128 threads). Aggregate jobs/s on that machine sat near **~7 /s** (about **~6.8 /s** through 2,000 on the smaller packing knobs). That is half a dual-socket node, not a chip that cannot pack. One socket was already hard to find on the clock we had. We have since found a **dual-socket 9575**. That was not easy. The matched ladder is **running now**. Until that file is in, do not treat ~7 jobs/s as the dual-socket 9575 number.

**9J45 was miscalibrated because the client sat on a laptop.** The old Turin **9J45** packing curve (about **~10 jobs/s** through 704) was driven from a laptop into the node. Create-path RTT and the HTTP pool throttled the wave. Guests never saw a fully driven dual-socket box, so jobs/s looked like a software cap. This time we **SSH onto the node and run the harness next to the runner**, the same way we already did on Vera (`ipp8-d15-c2-vera-2`). 9J45 is `oc5002`. Same on-node placement on both sides.

On that matched setup, 9J45 packing is about **~18.8 jobs/s**, not ~10. Vera is still ahead at about **~22 jobs/s**. The gap is smaller than the laptop curve implied. It is still a real gap on a fair dual-socket compare.

## What to take away

On **Vera**, throughput stays near **~22 jobs/s** from 880 through 2,000. On **Zen 5 (9J45)**, the same 0.125 vCPU / 512 MiB packing stays near **~18.8 jobs/s**.

The spike at 352 is that batch of jobs finishing together, not a higher lasting rate.

9J45 is the high core-count Zen 5 SKU. Vera still packs more completed episodes per second at every rung.

Both series use the **same concurrency ladder** on the x-axis through **2,000**.

![Agent task — throughput vs concurrency (higher is better)](throughput_vs_concurrency.png)

![Agent task — in-sandbox p50 duration vs concurrency (lower is better)](duration_vs_concurrency.png)

## How to read the charts

**Throughput (jobs per second)** is completed sandbox episodes divided by the wave's exec wall clock. Higher is better.

**p50 duration_ms** is the median time spent *inside* the sandbox doing the agent loop. Lower is better.

## Fair comparison (why this is as matched as we can make it)

Both cells ran the **same agent task** (`repo-agent-v3`), **same snapshot** (`dtgraviet/vera-agent-benchmark:v3`), **same** `--n 50`, **seed 42**, `-E 8`, and `--hold-then-exec`. Both use the **identical concurrency ladder** from **44** through **2,000**:

```text
44  88  132  176  264  352  528  704  880  1056  1408  1760  2000
```

**Both boxes are dual-socket.** Vera is one dual-socket NVIDIA cell (**176** physical cores). Zen 5 (9J45) is one dual-socket AMD EPYC Turin cell on Phoenix (`oc5002`, **192** physical cores / **384** threads). Each series is a **single node**, not a multi-host spread. The client sat **on that node** next to the RLP runner (Vera: `ipp8-d15-c2-vera-2`. 9J45: `oc5002`). Laptop-to-cell runs are not in this compare.

**At concurrency 44 through 704**, both used the **same reserved capacity**: 0.125 vCPU and 1 GiB memory per sandbox. Burst caps are the same (1 vCPU, 4 GB RAM).

**From 880 onward**, both stay on **0.125 vCPU / 512 MiB**. Burst caps are unchanged:

|                  | Vera       | Zen 5 (9J45) |
| ---------------- | ---------- | ------------ |
| CPU guarantee    | 0.125 vCPU | 0.125 vCPU   |
| CPU burst cap    | 1 vCPU     | 1 vCPU       |
| Memory guarantee | 512 MiB    | 512 MiB      |
| Memory burst cap | 4 GB       | 4 GB         |

That is the same packing shape on both chips through **2,000**. No reservation trick is required. Each sandbox still **bursts to a full 1 vCPU and up to 4 GB RAM** during the agent episode. All rungs in this compare finished with **zero failures**.

## Configuration

| Setting          | Reserved capacity (c=44..704)                                                  | Max-pack (c=880+) |
| ---------------- | ------------------------------------------------------------------------------ | ----------------- |
| Target           | `--target vera` or `--target us-phoenix-1`                                     | same              |
| CPU guarantee    | **0.125** vCPU                                                                 | **0.125** vCPU    |
| CPU burst cap    | **1.0** vCPU                                                                   | **1.0** vCPU      |
| Memory guarantee | **1 GiB** (default)                                                            | **512 MiB**       |
| Memory burst cap | **4 GB**                                                                       | **4 GB**          |
| Shared           | `--n 50 --seed 42 -E 8 --hold-then-exec` · `dtgraviet/vera-agent-benchmark:v3` | same              |
| Client           | on-node (Vera `ipp8-d15-c2-vera-2` · 9J45 `oc5002`)                            | same              |

### Vera — two runs, matched ladder

**Step 1 — reserved capacity (1 GiB, c=44..704). Run from the Vera node:**

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 44 88 132 176 264 352 528 704 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1
```

**Step 2 — max-pack (512 MiB guarantee, c=880..2000). Same node:**

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 880 1056 1408 1760 2000 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5 --rlp-memory-max 4
```

### Zen 5 (9J45) — two runs, matched ladder

**Step 1 — reserved capacity (1 GiB, c=44..704). Run from the Phoenix runner (`oc5002`), not a laptop:**

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 44 88 132 176 264 352 528 704 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1
```

**Step 2 — max-pack (512 MiB guarantee, c=880..2000). Same node (`oc5002`):**

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 880 1056 1408 1760 2000 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5 --rlp-memory-max 4
```

## Headline numbers (matched rungs)

**Through 704** = same reserved capacity on both. **880–2,000** = same 0.125 vCPU / 512 MiB max-pack on both.

| Concurrency | Vera p50  | 9J45 p50  | Vera tput | 9J45 tput |
| ----------- | --------- | --------- | --------- | --------- |
| 704         | 25,190 ms | 31,055 ms | 22.44 /s  | 19.07 /s  |
| 880         | 33,741 ms | 33,655 ms | 22.56 /s  | 18.81 /s  |
| 1,056       | 28,896 ms | 40,362 ms | 22.03 /s  | 18.70 /s  |
| 1,408       | 51,098 ms | 58,106 ms | 22.38 /s  | 18.81 /s  |
| 1,760       | 62,400 ms | 78,632 ms | 21.72 /s  | 18.79 /s  |
| 2,000       | 67,342 ms | 95,260 ms | 22.59 /s  | 18.86 /s  |

Vera's p50 looking shorter at 1,056 than at 880 is the middle sandbox staying lucky while the slow ones got slower, not the machine speeding up.

## Method notes

- Charts merge Step 1 + Step 2 JSONL per series.
- Base 704 narrative: [`../nvidia-agent-brief-704-zen5/`](../nvidia-agent-brief-704-zen5/)
- Sources: [`sources.md`](sources.md)
- Dual-socket 9575 ladder is in flight. Do not mix the old one-socket ~7 /s line into this 9J45 compare.

# Agent max-pack ladder — data inventory

**Date:** 2026-08-28  
**Brief:** [`nvidia-agent-brief-maxpack.md`](nvidia-agent-brief-maxpack.md)  
**Scope:** Coding-agent max-pack runs at concurrency **704 and above**  
**Target ladder:** Vera/Phoenix `704 880 1056 1408 1760 2112 2464 2784` (512 MiB); Redswitches `704 … 2000` (100 MiB)

Base ladder through c=704 (1 GiB) is complete for all three cells — see [`../nvidia-agent-brief-704-zen5/`](../nvidia-agent-brief-704-zen5/).

---

## Status legend

| Symbol | Meaning |
|--------|---------|
| ✅ | **Clean** — 0 create failures, chart-ready |
| ⚠️ | **Usable with caveats** — 0–few create fails and/or minor checksum drift; OK for directional charts |
| 🔶 | **Partial** — level ran but significant create loss; do not use for headline claims |
| ❌ | **Missing** — level not in file / run cancelled before it started |
| 🚫 | **Not usable** — attempted; ~100% create failures |

---

## Coverage matrix

Pinned file per series — details in [`sources.md`](sources.md).

| Level | Vera | Phoenix (9J45) | Redswitches (9575F) |
|------:|:----:|:--------------:|:-------------------:|
| **704** | ⚠️ | ✅ | ✅ (base 1 GiB) |
| **880** | ⚠️ | ✅ | ✅ |
| **1056** | ⚠️ | ✅ | ✅ |
| **1408** | ⚠️ | ✅ | ✅ |
| **1760** | ⚠️ | ✅ | ✅ |
| **2000** | ✅ (Vera 2112 remapped) | ✅ | ✅ |
| **2112** | 🔶 | 🚫 | — |
| **2464** | 🔶 | 🚫 | — |
| **2784** | 🔶 | 🚫 | — |

**Bottom line:** All three series now have a clean matched ladder through **2,000**. Vera and Phoenix share 0.125 vCPU / 512 MiB from 880. Redswitches uses 0.025 / 100 MiB packing knobs.

---

## Charts (best data on disk)

Base ladder (1 GiB, c=1..704) plus max-pack extension where available.

![Agent task — throughput vs concurrency (higher is better)](throughput_vs_concurrency.png)

![Agent task — in-sandbox p50 duration vs concurrency (lower is better)](duration_vs_concurrency.png)

Regenerate: `uv run python scripts/nvidia_brief_maxpack_charts.py`

---

## Vera — reference series (mostly complete)

**File:** `data/agent/rlp-vera-c0p125-max1-m512/concurrency_20260826_230252_n50.jsonl`  
**Client:** on-node (`ipp8-d15-c2-vera-2`)

| Level | Create fails | Runs | Expected | Throughput | p50 duration | Notes |
|------:|-------------:|-----:|---------:|-----------:|-------------:|-------|
| 704 | 0 | 5632 | 5632 | 22.2 /s | 25.8 s | ⚠️ minor checksum drift (17/5632 rows) |
| 880 | 0 | 7040 | 7040 | 22.6 /s | 33.7 s | same |
| 1056 | 0 | 8448 | 8448 | 22.0 /s | 28.9 s | same |
| 1408 | 0 | 11264 | 11264 | 22.4 /s | 51.1 s | same |
| 1760 | 0 | 14080 | 14080 | 21.7 /s | 62.4 s | same |
| 2112 | 54 | 16518 | 16896 | 22.7 /s | 67.3 s | 🔶 ~97% sandboxes live |
| 2464 | 439 | 16639 | 19712 | 22.8 /s | 66.0 s | 🔶 ~84% sandboxes live |
| 2784 | 739 | 17099 | 22272 | 23.7 /s | 71.0 s | 🔶 ~73% sandboxes live |

---

## Phoenix (9J45) — clean through 2,000

**Files:** glue `…125904` (704, 880) + `…104841` (1056–2000)  
**Client:** on-node (`oc5002`). Same 0.125 / 512 MiB shape as Vera.

| Level | Create fails | Runs | Expected | Throughput | p50 duration | Status |
|------:|-------------:|-----:|---------:|-----------:|-------------:|--------|
| 704 | 0 | 5632 | 5632 | 19.07 /s | 31.1 s | ✅ glue `…125904` |
| 880 | 0 | 7040 | 7040 | 18.81 /s | 33.7 s | ✅ glue `…125904` |
| 1056 | 0 | 8448 | 8448 | 18.70 /s | 40.4 s | ✅ |
| 1408 | 0 | 11264 | 11264 | 18.81 /s | 58.1 s | ✅ |
| 1760 | 0 | 14080 | 14080 | 18.79 /s | 78.6 s | ✅ |
| 2000 | 0 | 16000 | 16000 | 18.86 /s | 95.3 s | ✅ |

44–528 stay on 1 GiB `…115935`. Laptop `…012143` and the 26 s 880 in `…104841` are superseded.

**Runbook:** [`../tickets/phoenix-agent-maxpack-run.md`](../tickets/phoenix-agent-maxpack-run.md)

---

## Redswitches (9575F) — clean through 2,000

**File:** `data/agent/rlp-redswitches-c0p025-max1-m100/concurrency_20260828_225238_n50.jsonl`  
**Branch:** `redswitches-2k` (Vedran) · **Client:** on-node (`rs-vl-us-15`)  
**Runbook:** [`../tickets/redswitches-2k-maxpack-run.md`](../tickets/redswitches-2k-maxpack-run.md)

| Level | Create fails | Runs | Throughput | p50 duration | Status |
|------:|-------------:|-----:|-----------:|-------------:|--------|
| 704 | 0 | 5632 | 6.89 /s | 99.3 s | ✅ |
| 880 | 0 | 7040 | 6.83 /s | 127.2 s | ✅ |
| 1056 | 0 | 8448 | 6.80 /s | 149.7 s | ✅ |
| 1408 | 0 | 11264 | 6.81 /s | 195.9 s | ✅ |
| 1760 | 0 | 14080 | 6.84 /s | 244.8 s | ✅ |
| 2000 | 0 | 16000 | 6.82 /s | 279.8 s | ✅ |

Supersedes failed `rlp-redswitches-c0p125-max1-m512/…194955` ([old ticket](../tickets/eng-redswitches-maxpack-create-failures.md)).

---

## What we have vs what we need

| Need | Vera | Phoenix | Redswitches |
|------|:----:|:-------:|:-----------:|
| Clean 704–880 | ⚠️ | ✅ | ✅ |
| Clean 1056–1408 | ⚠️ | ✅ | ✅ (100 MiB shape) |
| Clean 1760–2000 | 🔶 Vera 2112 remapped | ✅ | ✅ |

Phoenix 880–2000 is closed.

---

## Related artifacts

| Item | Path |
|------|------|
| Base 704 brief (3-series) | [`../nvidia-agent-brief-704-zen5/`](../nvidia-agent-brief-704-zen5/) |
| Chart script | `scripts/nvidia_brief_maxpack_charts.py` |
| Redswitches 2k runbook | [`../tickets/redswitches-2k-maxpack-run.md`](../tickets/redswitches-2k-maxpack-run.md) |
| Vera max-pack run (coworker) | `tickets/coworker-vera-maxpack-run.md` |

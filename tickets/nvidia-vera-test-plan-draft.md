# Vera × Daytona onsite tests — draft for NVIDIA

**Status:** Draft for review  
**Audience:** NVIDIA Vera / partnership contacts (Tom, Diana, Ananya, Ian, et al.)  
**Owner:** Daniel Graviet  
**Date:** 2026-08-12  
**Related:** `tickets/gtc-berlin-vera-daytona-compelling-data.md`, `tickets/onsite-vera-gtc-runbook.md`, `tickets/evals-terminal-bench-style.md`

---

## What we want to learn

We want to know whether **Vera makes Daytona’s sandbox product clearly better for the workloads our customers run** — coding agents, data/analytics jobs, RL-style rollouts, and eval / Terminal-Bench–style trials — such that **ROI and UX improve** (faster completion, higher density, more predictable latency).

Daytona software still owns routing, snapshotting, portability, isolation/security, and scheduling. What we want from Vera is **evidence that the same Daytona paths run better on Vera than on today’s ARM64/X86 regions**, so we can justify preferring Vera capacity.

## Daytona SW / components we’d test on Vera

1. **Sandbox lifecycle** — create → exec → delete (and warm reuse where we already support it)
2. **Snapshot boot path** — region-local snapshots / images for our workload packs
3. **Concurrent multi-tenant density** — many isolated sandboxes on one node (up to ~88 workers in our harness)
4. **In-sandbox customer compute** — the work *inside* the sandbox (exclude API round-trips)

## Prioritized tests (and why)

| Priority | Test | Why it matters to Daytona |
| --- | --- | --- |
| **P0** | **RL / agent-style rollout CPU** (heavy in-sandbox episode; compare `duration_ms`) | Isolates **silicon quality** for sequential agent/RL-style work — the claim “Vera cores finish the same episode faster.” |
| **P0** | **Sandbox density** (light RL + coding-agent + **evals / TB-style** `--n 1` trials at concurrency 1→88) | Isolates **product density / UX** — more concurrent customer jobs with usable p99. Closest to Terminal-Bench–on-Daytona style load. |
| **P1** | **Analytics / Parquet + DuckDB** | Memory-bandwidth–heavy tenants; keep if it wins, otherwise appendix. |
| **P1** | **Cold create / schedule tax** (light workload size) | Separately measure spin-up (API, scheduling, etc.) |
| **P2** | **Harbor Terminal-Bench oracle** (`uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0`, Vera vs control) | “TB oracle pack finishes sooner / denser on Vera” — **infra time-to-finish** (see `tickets/evals-terminal-bench-style.md`) |

## What we’d like to confirm with hard numbers

Against an **apples-to-apples** control (same snapshots, same seeds/checksums, same concurrency ladder) on today’s region (e.g. current ARM64 test region) vs **Vera as a dedicated Daytona/RLP region**:

- In-sandbox work is **faster on Vera** (`duration_ms`), not just better network to that region
- At high concurrency, **throughput goes up** and **p99 stays usable**
- **Fewer failures / flaky capacity** under load
- Warm reuse path (where we strip create) shows wall time tracking in-sandbox compute

## What “win” looks like for us

A clear, publishable gap on Vera vs control on the metrics below

## 3–5 decision metrics

1. **`duration_ms` p50 / p99** (heavy RL episode) — Vera vs control (**chip**)
2. **Throughput (trials or episodes / sec)** at 44–88 concurrent sandboxes (**density / ROI**)
3. **p99 end-to-end latency** at 88 (**UX / predictability**)
4. **Failure / incomplete rate** under the density matrix (**reliability**)
5. **Time to complete a fixed eval / TB-oracle pack** at fixed concurrency (**customer-facing eval UX**)

---

We’ll follow with a more detailed run matrix and exact commands as a weekend draft. Happy to take comments from Tom / Diana / Ananya / Ian on format or anything you’d like us to emphasize technically.

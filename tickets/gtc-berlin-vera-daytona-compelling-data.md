# GTC Berlin: Vera × Daytona compelling-data plan

**Status:** Open  
**Product:** Vera agent concurrency harness (`arm64-benchmark-1`) + Daytona / RLP  
**Severity:** High — blocks a clean NVIDIA GTC Berlin narrative  
**Date:** 2026-08-11  
**Reporter:** Daniel Graviet  
**Goal:** Leave HQ / Vera runs with data that shows Vera chips are a strong fit for Daytona and that Daytona moves customer bottom line on Vera (Berlin GTC).

**Ops runbook:** `tickets/onsite-vera-gtc-runbook.md`

---

## Summary

Harness wall `latency_ms` includes sandbox **create → schedule → exec**. Light RL episodes cannot support a “Vera cores are faster” claim.

**Hardened RL (`rl-rollout-v2`):** batched policy/env — on Daytona **`duration_ms` ≈ 4.6 s at `--n 5000`** (warm `-E` latency tracks it). Chart B stays at `--n 64` (~50 ms `duration_ms`, create-dominated).

**Sandbox reuse:** `--episodes-per-sandbox` / `-E` on Daytona/RLP (create once → exec E times → delete). Chart A uses `-E 8` (warm). Chart B always `-E 1`.

GTC messaging must split **Chart A — is the chip faster?** (`duration_ms`) from **Chart B — does Daytona scale on Vera?** (throughput / p99 at 88 sandboxes, `E=1`).

Do **not** treat today’s `rlp-arm64` (`arm64-test-1`) as a Vera preview for faster silicon.

---

## Customer / GTC story (one sentence)

> On Vera, Daytona runs **88 concurrent customer rollouts** with **stable per-episode CPU**, and those episodes finish **X% faster** than on today’s region — so RL/agent tenants get higher effective density without rewriting their agents.

Only claim the “X% faster” clause if Vera `duration_ms` beats controls by a clear margin (≥20–30%).

---

## What to measure (priority order)

### A) Chip story — is the chip itself faster?

**In plain terms:** run the **same heavy RL episode** (same `--n`, same seed) on today’s Daytona region and on Vera. Ignore sandbox create / API / network time. Only compare **`duration_ms`** — how long the work takes *inside* the sandbox.

- If Vera’s `duration_ms` is clearly lower → you can say Vera cores finish the episode faster.
- If not → don’t claim that.

That’s Chart A: one apples-to-apples CPU timing, Vera vs control.

| Item | Value |
| --- | --- |
| Benchmark | `rl` (`rl-rollout-v2`) |
| `--n` | **`5000`** (~4.6 s `duration_ms` on Daytona) |
| `-E` | **`8`** (sandbox reuse; warm episodes cross-check) |
| Levels | `1` and `88` |
| Metric | **`duration_ms` only** (p50 / p99) — not mean `latency_ms` |
| Controls | Daytona default region and/or `rlp-x86` |
| Target | Vera RLP/Daytona region via `--target <vera-region>` |

Headline shape: *“Same mocked rollout episode: ~3 s elsewhere → Xs on Vera.”*

### B) Product story — can Daytona pack a lot of work onto Vera at once?

**In plain terms:** spin up many sandboxes at the same time (up to 88) with a **light** workload, and check whether things stay usable: throughput goes up, p99 latency doesn’t fall apart, and per-episode CPU stays roughly flat.

That’s not “is the chip faster?” — that’s “does Daytona scale on Vera?”

| Item | Value |
| --- | --- |
| Benchmarks | `rl` light (`--n 64`) and/or `agent` (`repo-agent-v2`, `--n 20`) |
| `-E` | **`1`** (fresh sandbox per episode) |
| Levels | `1 8 22 44 88` |
| Metrics | **throughput** + **p99 `latency_ms`**; also confirm `duration_ms` stays flat at 88 |
| Point | Sandbox density / isolation on 88 Olympus cores |

Headline shape: *“88 concurrent Daytona sandboxes on Vera with flat episode CPU and usable p99.”*

### C) Optional — bandwidth customer

| Item | Value |
| --- | --- |
| Benchmark | `analytics` (DuckDB) and/or `media` (FFmpeg) |
| `--n` | analytics **`200`** (~2.3 s local); media **`40`** (multi-second `duration_ms`) |
| Metric | `duration_ms` / throughput at high concurrency |
| Use | Bandwidth / 3×-per-core claim; keep whichever wins on Vera, else appendix |

Media is a Chart C sibling (agent-style transcode), not a second AMD-style suite.

---

## Minimum run matrix

```bash
# A) Chip story (reuse for warm wall cross-check; claim from duration_ms)
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 88 --n 5000 --seed 42 -E 8
# Same on Daytona default and/or rlp-x86 for control

# B) Product story (density — always E=1)
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 64 --seed 42 -E 1
uv run main.py --benchmark agent --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 20 --seed 42 -E 1
```

Same snapshot workload, same `--seed`, checksum agreement across backends.

---

## Evidence / baselines (hardened workloads, local)

| Workload | `--n` | ~`duration_ms` | Role |
| --- | ---: | ---: | --- |
| RL light | 64 | ~50 ms on Daytona | Chart B density |
| **RL Chart A** | **5000** | **~4.6 s on Daytona** | Chip story |
| Agent Chart B | 20 | multi-step tmp workspace | Density / customer shape |
| Analytics Chart C | 200 | ~2.3 s local | Optional bandwidth |
| Media Chart C | 40 | multi-second (FFmpeg) | Optional BW sibling |

Create/schedule tax remains ~2–3 s on cold episodes — use `duration_ms` (and warm `-E` latency) for chip claims.

---

## What not to lead with at GTC

1. Mean harness `latency_ms` at heavy `--n` without separating cold create.
2. Current `arm64-test-1` results as proof Vera is faster.
3. Chart B runs with `-E > 1` framed as density.
4. Blaming Python GC / placement as the narrative — measure around it (`duration_ms`, fixed snapshot, fixed `n`/`seed`).

---

## Build follow-ups (harness)

| Priority | Item | Status |
| --- | --- | --- |
| P0 | EDA chart **`duration_ms` vs concurrency** | Done (`p50_duration_bars.png`) |
| P1 | **sandbox reuse** `--episodes-per-sandbox` | Done (daytona/rlp) |
| P2 | Document Vera `--target` in RUNBOOK once region exists | Open — fill `harness/regions.py` onsite |

---

## Success criteria for Berlin

- [ ] Vera region access + RL snapshot built (`--benchmark rl --target <vera>`)
- [ ] Chart A: same heavy episode on Vera vs control; compare only `duration_ms` (clear gap or we drop chip brag)
- [ ] Chart B: many concurrent sandboxes on Vera (up to 88, light `--n`, `E=1`); throughput up, usable p99, flat episode CPU
- [ ] One-sentence customer bottom-line slide locked to whichever gap is real
- [ ] Checksums match across regions for the same `(n, seed)`

---

## Decision rule

- If **A** shows a clear `duration_ms` win → lead with chip + density.  
- If **A** is flat/noisy but **B** is strong → lead with **Daytona scales on Vera** (still on-brand; don’t overclaim FLOPs).  
- Never mix light-`n` create/API latency into a “Vera cores are faster” headline — that is not Chart A.

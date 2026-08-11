# GTC Berlin: Vera × Daytona compelling-data plan

**Status:** Open  
**Product:** Vera agent concurrency harness (`arm64-benchmark-1`) + Daytona / RLP  
**Severity:** High — blocks a clean NVIDIA GTC Berlin narrative  
**Date:** 2026-08-11  
**Reporter:** Daniel Graviet  
**Goal:** Leave HQ / Vera runs with data that shows Vera chips are a strong fit for Daytona and that Daytona moves customer bottom line on Vera (Berlin GTC).

---

## Summary

Current harness `latency_ms` is dominated by sandbox **create → schedule → exec → delete**. Light RL episodes (`--n 64`) are ~10–15 ms of CPU and cannot support a “Vera cores are faster” claim.

At `--n 100_000` on Daytona, in-container **`duration_ms` ≈ 3 s** (~50–60% of wall latency). That is the first useful CPU regime. Mean latency alone is still muddy (~2–3 s create tax). GTC messaging must split **chip quality** (`duration_ms`) from **Daytona product density** (throughput / p99 at 88 sandboxes).

Do **not** treat today’s `rlp-arm64` (`arm64-test-1`) as a Vera preview for faster silicon — at `n=5000`, ARM64 `duration_ms` was ~slower than Daytona default (~330 ms vs ~170 ms).

---

## Customer / GTC story (one sentence)

> On Vera, Daytona runs **88 concurrent customer rollouts** with **stable per-episode CPU**, and those episodes finish **X% faster** than on today’s region — so RL/agent tenants get higher effective density without rewriting their agents.

Only claim the “X% faster” clause if Vera `duration_ms` beats controls by a clear margin (≥20–30%).

---

## What to measure (priority order)

### A) Chip story — Vera sequential core quality

| Item | Value |
| --- | --- |
| Benchmark | `rl` |
| `--n` | `100000` (validated on Daytona) |
| Levels | `1` and `88` |
| Metric | **`duration_ms` only** (p50 / p99) — not mean `latency_ms` |
| Controls | Daytona default region and/or `rlp-x86` |
| Target | Vera RLP/Daytona region via `--target <vera-region>` |

Headline shape: *“Same mocked rollout episode: ~3 s elsewhere → Xs on Vera.”*

### B) Product story — Daytona concurrency on Vera

| Item | Value |
| --- | --- |
| Benchmarks | `rl` light (`--n 64` or `1000`) and/or `agent` (`--n 20`) |
| Levels | `1 8 22 44 88` |
| Metrics | **throughput** + **p99 `latency_ms`**; also confirm `duration_ms` stays flat at 88 |
| Point | Sandbox density / isolation on 88 Olympus cores |

Headline shape: *“88 concurrent Daytona sandboxes on Vera with flat episode CPU and usable p99.”*

### C) Optional — bandwidth customer

| Item | Value |
| --- | --- |
| Benchmark | `analytics` (mid/high `--n`) |
| Metric | `duration_ms` / throughput at high concurrency |
| Use | Only if it beats the control region; else appendix |

---

## Minimum run matrix

```bash
# A) Chip story
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 88 --n 100000
# Same on Daytona default and/or rlp-x86 for control

# B) Product story
uv run main.py --benchmark rl --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 64
uv run main.py --benchmark agent --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 20
```

Same snapshot workload, same `--seed`, checksum agreement across backends.

---

## Evidence already in-repo (Daytona `rl`)

| `--n` | mean `duration_ms` (approx) | Share of `latency_ms` @ c=1 | Notes |
| --- | ---: | ---: | --- |
| 64 | ~10–15 ms | ~0% | Provider/create story only |
| 10 000 | ~300–360 ms | ~10–13% | Still create-dominated |
| **100 000** | **~3.0–3.1 s** | **~48–61%** | First CPU-useful regime; `duration_ms` flat 1→88 |

Create/schedule tax remains ~2–3 s even at `n=100000`.

---

## What not to lead with at GTC

1. Mean harness `latency_ms` at heavy `--n` (create tax still large).
2. Current `arm64-test-1` results as proof Vera is faster.
3. Blaming Python GC / placement as the narrative — measure around it (`duration_ms`, fixed snapshot, fixed `n`/`seed`).

---

## Build follow-ups (harness)

| Priority | Item | Why |
| --- | --- | --- |
| P0 | EDA / slides chart **`duration_ms` vs concurrency** beside `latency_ms` | Makes chip claim honest without Phase 2 |
| P1 | Phase 2: **sandbox reuse** (many episodes per sandbox) | Strips create/delete from wall time for cleaner silicon comparison |
| P2 | Document Vera `--target` + snapshot name in RUNBOOK once region exists | Same path as `arm64-test-1` |

---

## Success criteria for Berlin

- [ ] Vera region access + RL snapshot built (`--benchmark rl --target <vera>`)
- [ ] Chart A: `duration_ms` @ `n=100000`, c=1 and c=88, Vera vs control (clear gap or we drop chip brag)
- [ ] Chart B: throughput + p99 @ levels → 88 on Vera (density / Daytona product)
- [ ] One-sentence customer bottom-line slide locked to whichever gap is real
- [ ] Checksums match across regions for the same `(n, seed)`

---

## Decision rule

- If **A** shows a clear `duration_ms` win → lead with chip + density.  
- If **A** is flat/noisy but **B** is strong → lead with **Daytona scales on Vera** (still on-brand; don’t overclaim FLOPs).  
- Never mix light-`n` create latency into a “Vera cores” headline.

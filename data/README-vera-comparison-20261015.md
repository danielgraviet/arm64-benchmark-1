# Vera vs EPYC 9575F vs Turin vs Graviton5 — results index (Sep–Oct 2026)

Four single-host bench cells built from the **same Daytona source revision** (`f0611fa13` plus the bench patches kept
beside each cell's data) running the same harness and recipes. Every number below comes from the archives in this
directory. Hosts were development benchmark cells, not production.

| Cell | Hardware | Data |
|---|---|---|
| HQ Vera | NVIDIA Vera, 2 × 88 cores, SMT2 (352 threads), 1,479 GiB | `vera-hq-cell-20261014/` |
| EPYC 9575F | AMD Zen 5, 1 × 64 cores, SMT2 (128 threads), 1,133 GiB | `vera-hq-cell-20261014/` (baselines + `epyc9575-*.tgz`) |
| Turin (OCI `phoenix-e6`) | AMD EPYC 9J45, 2 × 96 cores, SMT2 (384 threads), 2,267 GiB | `phoenix-e6-cell-20261014/` |
| Graviton5 (AWS m9gd) | Neoverse-V3, 192 cores, no SMT, 754 GiB | `graviton5-cell-20261014/` |

## Headline results

| Measurement | HQ Vera | Turin | Graviton5 | EPYC 9575F |
|---|---:|---:|---:|---:|
| Agent throughput at 2,000 sandboxes (jobs/s) | **26.25** | 22.15 | 23.38 | 8.02 |
| Jobs/s per physical core | **0.149** | 0.115 | 0.122 | 0.125 |
| Job p50 at 2,000 sandboxes (s) | **32.0** | 79.6 | 83.5 | 237.7 |
| Memory streaming, host plateau | **≈ 2.1 TB/s** | not run | ≈ 0.60 TB/s | ≈ 0.305 TB/s |
| Memory streaming, one sandbox (GB/s) | **72.3** | not run | 57.5 | 46.1 |
| Idle-image startup p50, 1k burst (s) | 1.57 | 2.35 | **0.85** | 1.06 |
| Highest density held cleanly | 2,000 (tested) | **8,000** | 2,000 (tested) | 2,000 (tested) |

The memory-streaming figures are **effective application traffic** from a STREAM-style triad kernel inside sandboxes
(24 bytes per element per pass, summed over concurrent sandboxes), not hardware DRAM counters or an official STREAM
submission. Vera's host has two sockets; Graviton5 and the 9575F have one each.

At a matched 64 sandboxes with zero failures on every host, completed passes in ~30 s were **≈ 134,000 (Vera)**,
45,018 (Graviton5) and 22,503 (9575F).

## Where to start

| Question | Read |
|---|---|
| How to run any of this without repeating our mistakes | `../docs/benchmark-methodology.md` |
| Full write-up of every test, with caveats | `gapfill-20261014/vera-benchmark-report-20261015-v3.pdf` |
| Power + memory-bandwidth method and results | `vera-hq-cell-20261014/power-mem-20261015/RESULTS.md` |
| Per-cell setup, config and findings | `<cell>/FINDINGS.md`, `<cell>/README.md`, `<cell>/RUNBOOK.md` |
| Where create time actually goes, per step | `vera-hq-cell-20261014/CREATE-PATH-STEPS.md` |
| Independent re-check of the published numbers | `gapfill-20261014/audit-power-memory.py` → `power-memory-audit-20261015.json` |

## Reproducing

1. Bring a cell to the reference state: `scripts/host/bench-preflight.sh` must print `PREFLIGHT PASS` and
   `create_path_fixes ON`. Each cell's `scripts/` directory contains the exact setup scripts used.
2. Startup / throughput: `mpfleet.py` (16 processes) and `main.py --benchmark agent` with the published recipe,
   as recorded in each cell's `RUNBOOK.md`.
3. Power and memory bandwidth: `scripts/power-mem/` (see its `README.md`).

## Reading the numbers safely

- **Agent-image bursts measure startup under CPU load, not platform startup.** The image runs a CPU-bound entrypoint
  in every sandbox (~3–4 core-seconds). Use an idle image for startup. This invalidated several earlier conclusions.
- **Power scopes differ by vendor and are not interchangeable.** Vera's "AP Power" is not CPU-package-only; AMD RAPL
  package excludes DRAM and regulator losses. No whole-server efficiency ranking is established here.
- **Clock-under-load figures come from different methods** except Vera and the 9575F, which share the busy-core
  sampler in `scripts/power-mem/power-sampler.py`.
- **Failure counts belong next to every latency figure.** One wedged guest moves an "all ready" number by seconds.
- **Host public IPs were replaced with placeholders** (`<turin-host>`, `<graviton5-host>`, `<epyc9575-host>`) before
  publishing. Private addresses are kept because the runbooks need the topology.

## Known platform issues found while measuring

| Issue | Effect on benchmarks |
|---|---|
| daytona/rlp#3212 | 3 s Firecracker socket wait caused spawn timeouts and runner self-cordons; 30 s removes them |
| daytona/rlp#3213 | ~0.2 % of arm64 snapshot clones wedge after resume; holds "all ready" open |
| daytona/rlp#3229 | A sandbox counts as running when its toolbox port accepts, so a hung guest looks healthy |
| daytona/rlp#3260/#3261/#3265/#3269 | Create-path costs: init-disk fsync, serialized cgroup creation, a 580 ms post-resume ARP stall, and a 128-deep API accept queue |
| daytona/rlp#2459 | At ~8–10k live sandboxes the runner heartbeat starves and the lost-sweep orphans live VMs |
| daytona/rlp#1554 | `gcc:14` guests panic on this build (unquoted ENV in guest init) — use `buildpack-deps:bookworm` |
| daytona/rlp#767 | Arm64 clones keep the template's wall clock, so guest timestamps cannot be aligned with host telemetry |

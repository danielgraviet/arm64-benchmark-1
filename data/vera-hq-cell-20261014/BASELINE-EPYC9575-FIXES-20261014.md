# Baseline: EPYC 9575F, create-path fixes OFF vs ON, and the comparison with HQ Vera (2026-10-14)

**Reference results for later comparison.** Machine-readable: `BASELINE-EPYC9575-FIXES-20261014.json` (generated
from raw data by `scripts/create-path/make-9575.py`). Raw data: `epyc9575-fixes-bench.tgz`. The HQ Vera side is
`BASELINE-VERA-FIXES-20261014.md`.

**Both hosts run the fixes ON from 2026-10-14 ~22:20 UTC**, through the same `20-create-path-fixes.conf` drop-ins.
Preflight prints `create_path_fixes ON` on both.

## Setup: the same software on both hosts

| | EPYC 9575F | HQ Vera |
|---|---|---|
| CPU | AMD EPYC 9575F, 1 socket, 64 cores / 128 threads | NVIDIA Vera, 2 × 88 cores / 352 threads |
| kernel / page size | `7.0.0-38-generic` / 4 KiB | `6.17.0-1032-nvidia-64k` / 64 KiB |
| build | daytona `f0611fa13` + `patches/bench-build/` (identical source; runner `739fc73a116d`, api `93fa5e93bf20`) | same (runner `0fd55bab4ad6`, api `1648ab971fe5`) |
| daemon / Firecracker | `rlp-rs-0.4.1` / v1.16.1 | same |
| both arms | `RLP_FC_SOCK_WAIT_MS=30000`, `RLP_VM_CONCURRENCY=512`, `RLP_NETNS_POOL=2100`, `RLP_BURST_MAX_CPU=1` | same |
| host-specific | `RLP_VM_MAXACK=2048`, cpu.weight drop-ins (the host's existing tuning, kept) | defaults |
| fixes ON | `RLP_INITDISK_MODE=nofsync`, `RLP_CGROUP_POOL=1400`, `RLP_NEIGH_PERMANENT=1`, `RLP_API_LISTEN_BACKLOG=4096` | same |
| method | `bench-fixes-9575.sh`: identical commands, order and settings to Vera's `bench-fixes.sh` | |

**Before this run the 9575F ran older stock binaries** (API from Oct 2, runner `558f9862595d`). It now runs the same
`f0611fa13` build as Vera, and its stock binaries are kept as `/usr/local/bin/rlp-{runner,api}.bak-prepatch`.
"Fixes OFF" below is the bench build with the flags unset, *not* the old stock build.

## 1. Startup: 1,000 sandboxes, idle image (`alpine:3.20`) — 3 reps per arm

| | 9575F OFF | 9575F **ON** | Vera OFF | Vera **ON** |
|---|---|---|---|---|
| create p50 (s) | 2.47 / 2.58 / 2.49 | **1.10 / 0.98 / 1.09** | 2.07 / 2.39 / 2.32 | **1.51 / 1.62 / 1.59** |
| create p95 (s) | 3.36 / 3.91 / 3.76 | **1.59 / 1.60 / 1.57** | 3.30 / 3.76 / 3.46 | **2.54 / 2.61 / 2.57** |
| all ready (s) | 3.82 / 4.00 / 4.53 | **2.26 / 2.12 / 2.05** | 4.70 / 3.86 / 3.66 | 10.42¹ / 3.88 / **2.69** |
| failed | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 | 1 / 0 / 0 |
| API listen overflows | 490 / 0 / 510 | 0 / 0 / 0 | 210 / 0 / 447 | 0 / 0 / 0 |

## 2. Startup: 1,000 sandboxes, agent image (entrypoint runs `workload.agent`)

| | 9575F OFF | 9575F ON | Vera OFF | Vera ON |
|---|---|---|---|---|
| create p50 (s) | 7.83 / 7.84 / 7.88 | 6.60 / 6.63 / 8.28 | 13.58 / 11.77 / 13.53 | 13.72 / 11.84 / 7.55 |
| create p95 (s) | 18.03 / 17.94 / 17.98 | 16.61 / 18.50 / 16.53 | 21.64 / 21.86 / 25.64 | 23.90 / 26.05 / 21.73 |
| all ready (s) | 20.35 / 20.24 / 20.56 | 18.85 / 19.14 / 18.77 | 21.82¹ / 21.98 / 25.75¹ | 61.02¹ / 28.11 / 21.82 |
| failed | 0 / 0 / 0 | 0 / 0 / 0 | 1 / 0 / 1 | 2 / 0 / 0 |

¹ held open by failed sandboxes (guests wedged after resume, daytona/rlp#3213).

## 3. Throughput: dense ladder (jobs/s, failures)

| concurrency | 9575F OFF | 9575F ON | Vera OFF | Vera ON |
|---|---|---|---|---|
| 176 | 8.13, 0 | 8.01, 0 | 1.47², 8 | 15.17, 0 |
| 352 | 8.02, 0 | 8.05, 0 | **26.67**, 0 | **26.65**, 0 |
| 704 | 8.04, 0 | 8.01, 0 | 25.51, 0 | 25.62, 0 |

² wedged guests holding the rung (Vera's clean 176 rung on the same build: 15.0 jobs/s).
Level 704 comes from a rerun on both hosts with `RLP_HTTP_READ_TIMEOUT_S=600`. The first pass used 120 s, which cut
off healthy episodes on the 9575F (p50 83 s, p99 145 s at that level) and reported them as 522–594 "failures".


## 4. At 2,000 sandboxes (fixes ON, both hosts, 2026-10-14 ~22:30–23:15 UTC)

Same commands at twice the density: startup with 2,000 created at once, and the dense ladder at level 2,000
(16,000 jobs). Job timeout and client read timeout raised to 1,800 s on both hosts, because at this density a 9575F
job takes ~4 minutes. Host memory sampled every 5 s. Raw data: `run2k-epyc9575.tgz`, `run2k-vera.tgz`.

**Startup, 2,000 at once, idle image (`alpine:3.20`)**

| | 9575F | Vera |
|---|---|---|
| create p50 (s) | **2.46 / 2.34 / 2.40** | 3.00 / 2.79 / —³ |
| create p95 (s) | **3.63 / 3.57 / 3.57** | 6.40 / 6.57 / —³ |
| all ready (s) | **4.62 / 4.56** / 17.65⁴ | 6.59 / 7.23 / —³ |
| failed | 0 / 0 / 0 | 0 / 0 / 1 run lost³ |

**Startup, 2,000 at once, agent image**

| | 9575F | Vera |
|---|---|---|
| create p50 (s) | **19.7 / 19.6** | 29.4 / 27.5 |
| create p95 (s) | 49.6 / 61.5 | **46.1 / 54.0** |
| all ready (s) | 58.1 / 70.7 | **50.2 / 54.5** |
| failed | 0 / 0 | 0 / 2 (`dial tcp …:2280: i/o timeout`) |

**Throughput, level 2,000 (16,000 jobs)**

| | 9575F | Vera |
|---|---|---|
| jobs/s | 8.03 | **26.11** |
| job time p50 / p95 / p99 / max (s) | 239 / 352 / 435 / **553** | **34 / 186 / 241 / 357** |
| failures | 1 | 1 |
| peak host memory used | 393 of 1,133 GiB (35%) | 470 of 1,479 GiB (32%) |
| peak load average | 2,158 (128 threads) | 1,972 (352 threads) |

³ Vera's third idle run produced no result: one sandbox never answered and the client was killed by its 20-minute
outer limit (the wedged-guest pattern, daytona/rlp#3213/#3229).
⁴ No failures, but three creates took 11–18 s.

The one throughput failure on **each** host was the same: the proxy could not reach a sandbox's network for 10 s
(`bad gateway: dial tcp <ip>:2280: i/o timeout`). It happened on x86 too, so it is not the arm64 guest-crash family.

**What 2,000 shows**

- **Both hosts run 2,000 sandboxes at once with ≤1 failure per 16,000 jobs.** Memory is not close to a limit: the
  agent workload costs ~180 MiB per sandbox on both (9575F (393−26)/2,000 ≈ 184 MiB; Vera (470−131)/2,000 ≈ 170 MiB).
  The configured cap of 3,000 would use ~580 GiB on the 9575F, well within its 1,133 GiB.
- **Throughput does not grow with density.** 9575F 8.0 jobs/s at 176, 352, 704 and 2,000; Vera 25.5–26.7. Above the
  saturation point extra sandboxes only wait longer: a 9575F job takes 20 s at 176 and 239 s at 2,000.
- **Idle-image startup at 2,000: the 9575F is still ahead** (p50 2.4 vs 2.9 s, p95 3.6 vs 6.5 s). Both roughly
  double from 1,000, as expected for a queue-bound path.
- **Agent-image startup at 2,000 flips the tail:** the 9575F has the better median (19.7 vs 28 s) but Vera the
  better p95 and all-ready (50–55 vs 58–71 s), because 2,000 entrypoint jobs saturate the 9575F's 128 threads.
- **The harness's default 600 s job timeout is nearly hit on the 9575F at 2,000** (max job 553 s). At 3,000 the
  9575F would need ~375 s per job typically and over 800 s at the tail, so a 3,000 run must raise `--exec-timeout`
  or it will report timeouts as failures.

## What the comparison says

1. **The fixes help the 9575F more than Vera.** Idle-image create p50 drops **−57%** on the 9575F (2.51 → 1.06 s
   average) vs **−30%** on Vera (2.26 → 1.57 s); p95 −57% vs −27%.
2. **With the fixes on, the 9575F starts sandboxes faster than Vera.** Idle-image 1k burst: create p50 **1.06 s vs
   1.57 s**, p95 **1.59 s vs 2.57 s**, all ready **2.1 s vs 2.7 s**. Without the fixes the two were close (2.5 vs
   2.3 s p50). Likely reason (not measured per step on the 9575F): what remains of the startup path is
   single-threaded work (fork/exec, Firecracker spawn, serialized kernel operations), where the 9575F's clock
   (max 5.0 GHz, 4.7 measured unloaded) beats Vera's (3.36 GHz). A per-step run on the 9575F would confirm it.
3. **Agent-image startup:** the 9575F is ~1.5–2× faster at p50 either way (6.6–7.9 s vs 7.6–13.7 s) and has a much
   tighter tail. Vera's agent runs also had wedged-guest failures; the 9575F had none in 6,000 sandboxes.
4. **Throughput is unchanged by the fixes, and Vera stays ~3.3× ahead** (26.7 vs 8.0 jobs/s at 352). That is
   cores × per-core rate under full load: 352 vs 128 threads, and the 9575F loses ~24% clock when packed.
5. **The startup claim needs care.** "Vera starts sandboxes faster" was never true for the platform path (earlier:
   ~4 s for both with an idle image), and with the fixes on it is reversed. Vera's advantage is throughput.

## Caveats

- **Failures differ by host.** No wedged guests on the 9575F (4 KiB pages, x86) in 6,000 startup sandboxes plus three
  ladders. Vera (64 KiB pages, arm64) shows the post-resume oops family at ~0.2% (daytona/rlp#3213).
- **Host tuning was not equalized.** The 9575F keeps its own `RLP_VM_MAXACK=2048` and cpu.weight drop-ins; Vera runs
  defaults. The fixes OFF/ON comparison on each host is clean; the cross-host one carries that difference.
- **Measurement builds.** Same caveats as the Vera baseline (cgroup-pool adoption, nothing merged upstream).
- **The 9575F's earlier published numbers came from different software** (older binaries, the floor script on),
  so compare against this file, not against them.

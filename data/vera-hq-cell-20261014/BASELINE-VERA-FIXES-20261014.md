# Baseline: HQ Vera, create-path fixes OFF vs ON (2026-10-14)

**Reference results for later comparison.** Machine-readable copy with per-run values:
`BASELINE-VERA-FIXES-20261014.json` (generated from the raw data by `scripts/create-path/make-baseline.py`, not
transcribed). Raw data: `fixes-bench.tgz` (harness benchmarks), `patched-arms.tgz` (per-step create path).

**From 2026-10-14 ~21:00 UTC the cell runs with the fixes ON.** The EPYC 9575F now runs the same build with the
fixes ON too; the cross-platform comparison is `BASELINE-EPYC9575-FIXES-20261014.md`. That is the state new runs should be compared
against the "fixes on" column. Every preflight now prints `create_path_fixes ON|OFF|PARTIAL`; check it before
comparing.

## What was measured

| | |
|---|---|
| host | HQ Vera `10.96.8.228`: 2 × 88 cores × SMT2 (352 CPUs), kernel `6.17.0-1032-nvidia-64k` (64 KiB pages), `preempt=none`, 600 W per socket |
| placement | **unpinned** (both sockets) |
| build | daytona `f0611fa13` + `patches/bench-build/` (EROFS 4 KiB, `RLP_FC_SMT` inactive, `RLP_FC_SOCK_WAIT_MS`, the four fixes); runner `0fd55bab4ad6`, api `1648ab971fe5` |
| guest | daemon `rlp-rs-0.4.1`, Firecracker v1.16.1 (stock), guest kernel `6.12.34-rlp1-arm64` |
| runner env (both arms) | `RLP_FC_SOCK_WAIT_MS=30000 RLP_VM_CONCURRENCY=512 RLP_NETNS_POOL=2100 RLP_BALLOON=0`; API `RLP_BURST_MAX_CPU=1` |
| sandbox | 0.025 CPU, 64 MiB, 1 GiB disk, 1 vCPU |
| **fixes OFF** | all flags unset (= stock behaviour; the same binaries reproduced the pre-patch baseline in 4 control runs) |
| **fixes ON** | `RLP_INITDISK_MODE=nofsync` (#3260), `RLP_CGROUP_POOL=1400` (#3261), `RLP_NEIGH_PERMANENT=1` (#3265), `RLP_API_LISTEN_BACKLOG=4096` (#3269) |

Arms ran interleaved (off, on, off, on) on the same binaries, with preflight PASS before every rep.

## 1. Harness startup: 1,000 sandboxes

`mpfleet.py --procs 16 --count 1000` (harness logic, SDK polling 0.25 s ×1.5 → 2 s, `RLP_HTTP_MAX_CONNECTIONS=1024`,
`RLP_HTTP_READ_TIMEOUT_S=120`, probe `echo ready`). Values per rep.

**Idle image (`alpine:3.20`)**

| | fixes OFF | fixes ON |
|---|---|---|
| create p50 (s) | 2.07 / 2.39 / 2.32 | **1.51 / 1.62 / 1.59** |
| create p95 (s) | 3.30 / 3.76 / 3.46 | **2.54 / 2.61 / 2.57** |
| all ready (s) | 4.70 / 3.86 / 3.66 | 10.42¹ / 3.88 / **2.69** |
| failed sandboxes | 0 / 0 / 0 | 1 / 0 / 0 |
| API listen overflows | 210 / 0 / 447 | 0 / 0 / 0 |

**Agent image (`dtgraviet/vera-agent-benchmark:v3`)** — every sandbox runs `workload.agent` at boot

| | fixes OFF | fixes ON |
|---|---|---|
| create p50 (s) | 13.58 / 11.77 / 13.53 | 13.72 / 11.84 / 7.55 |
| create p95 (s) | 21.64 / 21.86 / 25.64 | 23.90 / 26.05 / 21.73 |
| all ready (s) | 21.82¹ / 21.98 / 25.75¹ | 61.02¹ / 28.11 / 21.82 |
| failed sandboxes | 1 / 0 / 1 | 2 / 0 / 0 |

¹ held open by failed sandboxes (guests that wedged after resume, daytona/rlp#3213); compare p95, not all-ready, for
those reps.

## 2. Harness throughput: dense ladder

`main.py --benchmark agent --hold-then-exec --n 45 --seed 42 -E 8 --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625
--rlp-memory-max 4 --rlp-disk 0.015625`, `RLP_HTTP_MAX_CONNECTIONS=512`, `RLP_HOLD_CREATE_BATCH=512`,
`RLP_HTTP_READ_TIMEOUT_S=120`.

| concurrency | fixes OFF (jobs/s, failures) | fixes ON (jobs/s, failures) |
|---|---|---|
| 176 | 1.47², 8 | 15.17, 0 |
| 352 | **26.67**, 0 | **26.65**, 0 |
| 704 | 25.93, 0 | 25.69, 4 |

Level 704 rerun with `RLP_HTTP_READ_TIMEOUT_S=600` (as on the 9575F): **25.51** OFF / **25.62** ON jobs/s, 0 failures
(`vera-tput704-rerun.tgz`).

² 8 episodes wedged in oopsed guests, each holding the rung 120 s. Not a platform result. A clean 176 rung on the
same build earlier measured 15.0 jobs/s.

## 3. Per-step create path (platform time, no client polling)

`stepclient.py`: raw HTTP, server long-poll `GET /vms/{id}?wait=running`, 16 processes; per-sandbox joins of client,
`audit_logs`, `vms`, JetStream ack timestamps and the runner journal. Idle image. Milliseconds, p50 / p90.

**1,000-sandbox burst** (OFF: 4 runs, 3,988 sandboxes; ON: 2 runs, 2,000 sandboxes)

| step | fixes OFF | fixes ON |
|---|---|---|
| client → API (HTTP, auth, audit) | 40 / 1072 | 32 / 61 |
| API before DB transaction | 18 / 80 | 45 / 72 |
| API DB insert, publish, commit, response | 10 / 35 | 13 / 55 |
| queue → runner handler | 793 / 1247 | 421 / 1172 |
| scratch + init-disk copy | 300 / 700 | 11 / 35 |
| Firecracker spawn + API socket | 63 / 180 | 200 / 289 |
| snapshot load + resume | 12 / 69 | 20 / 58 |
| guest toolbox accepts | 3 / 11 | 5 / 76 |
| cgroup, register, trigger | 201 / 381 | 139 / 269 |
| API long-poll answers client | 3 / 89 | 1 / 4 |
| **POST → running** | **1927 / 3035** (p99 3483, max 3758) | **1054 / 1748** (p99 2290, max 2373) |
| **POST → first exec done** | **1937 / 3055** | **1071 / 1777** |

**60 sequential creates, idle host**

| | fixes OFF | fixes ON |
|---|---|---|
| POST → running p50 / p90 / p99 | 67 / 75 / **658** | 64 / 69 / **73** |
| POST → first exec done p50 | 89 | 85 |
| toolbox stalls > 100 ms | 4 / 60 (max 580 ms) | **0 / 60** (max 2 ms) |

## At 2,000 sandboxes (fixes ON)

Startup idle p50 3.00 / 2.79 s, p95 6.40 / 6.57 s (third run lost to one wedged sandbox); agent p50 29.4 / 27.5 s;
throughput at level 2,000: **26.11 jobs/s**, 1 failure in 16,000, peak memory 470 of 1,479 GiB. Full table and the
side-by-side with the 9575F: `BASELINE-EPYC9575-FIXES-20261014.md` §4.

## How to compare a new run against this

1. Run `scripts/host/bench-preflight.sh` and confirm `create_path_fixes` reads the state you mean to compare, plus
   the same placement (`slice_cpus`) and binary SHAs.
2. Startup: `scripts/create-path/bench-fixes.sh` runs both arms; for a single state use its `startup()` command
   line (`mpfleet.py --procs 16 --count 1000` with the env above). Compare **create p50 and p95**; use all-ready
   only for runs with 0 failures.
3. Per-step: `scripts/create-path/steps-run.sh <tag> burst 1000 alpine:3.20 16` (and `seq 60`), then
   `steps-analyze.py`.
4. Expect run-to-run spread. Fixes-OFF p50 ranged 1.74–2.29 s across 4 per-step runs and 2.07–2.39 s across 3
   harness runs. A difference smaller than that spread is noise.

## Caveats

- **Cross-platform:** compare only with `BASELINE-EPYC9575-FIXES-20261014.md` (same build on the 9575F). The
  EPYC 9755 still runs other software.
- **Measurement builds, not upstream.** The cgroup pool breaks startup adoption of VMs that outlive a runner
  restart (pool-named cgroups); see the #3261 comment.
- **Templates were rebuilt at ~20:20 UTC** (per-template #3213 test). Template builds may differ in their rare
  post-resume oops rate, so a few failures per thousand can vary between template builds.
- **SDK polling inflates harness startup numbers** relative to the per-step client (−30% vs −45% from the same
  fixes).
- Agent-image startup and throughput are bound by guest CPU work; the fixes do not change them.

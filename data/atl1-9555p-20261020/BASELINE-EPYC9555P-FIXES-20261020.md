# Baseline: AMD EPYC 9555P (Paperspace atl1node853), create-path fixes ON (2026-10-20)

Same suite, commands and settings as the "fixes ON" columns and the 2,000-sandbox section of
[`BASELINE-EPYC9575-FIXES-20261014.md`](../vera-hq-cell-20261014/BASELINE-EPYC9575-FIXES-20261014.md) and
[`BASELINE-VERA-FIXES-20261014.md`](../vera-hq-cell-20261014/BASELINE-VERA-FIXES-20261014.md). All comparison
values below are copied from those two files.

- Machine-readable: `BASELINE-EPYC9555P-FIXES-20261020.json`, generated from the raw data by `make-9555p.py`.
- Raw data: `suite-atl1.tgz` (on the host: `/mnt/data/bench/suite-atl1-20261020_080819`). Driver: `atl-suite.sh` (runs the whole suite; set `T`/`BD` to use it on another cell).
- **0 failures in every run**: 16,000 startup sandboxes and 25,856 ladder jobs. Every preflight passed with
  `create_path_fixes ON`, and the API recorded 0 listen-queue overflows.
- Host public IPs are replaced with placeholders (`<node853-public>`), as in the rest of this directory.

## Setup

| | |
|---|---|
| host | `atl1node853` <node853-public> (Paperspace ATL1 datacenter, a DigitalOcean company; bare-metal HPE ProLiant DL325 Gen11, `atl1node853.mgmt.atl1.paperspace.com`), **1 × AMD EPYC 9555P**, 64 cores / 128 threads, 755 GiB, kernel `6.8.0-139-generic`, `/mnt/data` = 5 × NVMe RAID0 |
| software | **byte-identical to the EPYC 9575F baseline** (sha256 prefixes checked on both hosts): runner `739fc73a116d`, api `93fa5e93bf20`, Firecracker v1.16.1 `2fd0171309af`, guest kernel `vmlinux-6.8.12-rlp3` `a3ae79b93a20`, initdisk `4e59e8441b7a`, daemon `rlp-rs-0.4.1`. The harness, SDK and Python 3.13.16 were copied from the 9575F. |
| fixes ON | `RLP_INITDISK_MODE=nofsync`, `RLP_CGROUP_POOL=1400`, `RLP_NEIGH_PERMANENT=1`, `RLP_API_LISTEN_BACKLOG=4096` (same drop-ins as the other cells) |
| cell config | Same as the 9575F: `RLP_SNAPSHOTS=1`, `RLP_VM_CONCURRENCY=512`, `RLP_NETNS_POOL=2100`, `RLP_FC_SOCK_WAIT_MS=30000`, `RLP_BURST_MAX_CPU=1`, `RLP_BURST_MAX_MEM_MIB=4096`, `RLP_MIN_SCRATCH_MIB=16`; runner in the delegated `rlp.slice`, unpinned. |
| harness change | an `atl1` target, handled exactly like `epyc9575`. The host ran `harness-atl1-target.diff` on its copy of the harness; this branch has the same target in `harness/regions.py` / `paths.py`, with tests. |

**What still differs from the 9575F (host level only):**

| | 9555P (this run) | 9575F |
|---|---|---|
| host kernel | 6.8.0-139 | 7.0.0-38 |
| `RLP_VM_MAXACK` | default (256, like Vera) | 2048 |
| cpu.weight | defaults | guests (`rlp.slice/vms`) 100, runner 1000 |
| `/mnt/data` | 5 × NVMe RAID0 | root NVMe partition |
| memory | 755 GiB | 1,133 GiB |

## Results (fixes ON), side by side

**Startup, 1,000 sandboxes, idle image (`alpine:3.20`), 3 reps**

| | **EPYC 9555P** | EPYC 9575F | HQ Vera |
|---|---|---|---|
| create p50 (s) | 1.03 / 0.97 / 0.98 | 1.10 / 0.98 / 1.09 | 1.51 / 1.62 / 1.59 |
| create p95 (s) | 1.63 / 1.28 / 1.63 | 1.59 / 1.60 / 1.57 | 2.54 / 2.61 / 2.57 |
| all ready (s) | 2.25 / 1.76 / 2.24 | 2.26 / 2.12 / 2.05 | 10.42¹ / 3.88 / 2.69 |
| failed | 0 / 0 / 0 | 0 / 0 / 0 | 1 / 0 / 0 |

**Startup, 1,000 sandboxes, agent image (entrypoint runs `workload.agent`), 3 reps**

| | **EPYC 9555P** | EPYC 9575F | HQ Vera |
|---|---|---|---|
| create p50 (s) | **2.42 / 2.71 / 3.05** | 6.60 / 6.63 / 8.28 | 13.72 / 11.84 / 7.55 |
| create p95 (s) | **7.47 / 7.92 / 8.14** | 16.61 / 18.50 / 16.53 | 23.90 / 26.05 / 21.73 |
| all ready (s) | **8.19 / 8.41 / 8.46** | 18.85 / 19.14 / 18.77 | 61.02¹ / 28.11 / 21.82 |
| failed | 0 / 0 / 0 | 0 / 0 / 0 | 2 / 0 / 0 |

**Startup, 2,000 sandboxes at once**

| | **EPYC 9555P** | EPYC 9575F | HQ Vera |
|---|---|---|---|
| idle: create p50 (s) | **2.09 / 2.06 / 2.15** | 2.46 / 2.34 / 2.40 | 3.00 / 2.79 / —² |
| idle: create p95 (s) | 3.49 / 4.11 / 5.17 | **3.63 / 3.57 / 3.57** | 6.40 / 6.57 / —² |
| idle: all ready (s) | **4.56 / 4.41 / 5.52** | 4.62 / 4.56 / 17.65 | 6.59 / 7.23 / —² |
| agent: create p50 (s) | **7.62 / 7.62** | 19.7 / 19.6 | 29.4 / 27.5 |
| agent: create p95 (s) | **21.7 / 19.8** | 49.6 / 61.5 | 46.1 / 54.0 |
| agent: all ready (s) | **26.0 / 38.0** | 58.1 / 70.7 | 50.2 / 54.5 |
| failed | 0 in all 5 runs | 0 | 0, 2, 1 run lost² |

**Throughput, dense agent ladder (jobs/s, failures)**

| sandboxes | **EPYC 9555P** | EPYC 9575F | HQ Vera |
|---|---|---|---|
| 176 | 7.82, 0 | 8.01, 0 | 15.17, 0 |
| 352 | 7.88, 0 | 8.05, 0 | **26.65**, 0 |
| 704 | 7.68, 0 | 8.01, 0 | 25.62, 0 |
| 2,000 | 7.81, 0 | 8.03, 1 | **26.11**, 1 |
| job time at 2,000, p50 / p95 / p99 / max (s) | 248 / 342 / 404 / 477 | 239 / 352 / 435 / 553 | **34 / 186 / 241 / 357** |
| peak host memory at 2,000 | 390 of 755 GiB | 393 of 1,133 GiB | 470 of 1,479 GiB |
| peak load average at 2,000 | 2,138 (128 threads) | 2,158 (128 threads) | 1,972 (352 threads) |

¹ Held open by wedged guests after resume (daytona/rlp#3213).
² Vera's third idle run produced no result: one sandbox never answered (the wedged-guest pattern, #3213/#3229).

Level 704 used a 600 s read timeout and level 2,000 used 1,800 s job and read timeouts, the same as on the other cells.
At 2,000 the agent workload costs ~190 MiB per sandbox ((390 − 17) GiB / 2,000), close to the ~180 MiB measured on the
other two cells. The mean clock of busy CPUs was ~4.4 GHz during the idle-image bursts and ~3.5–3.7 GHz during the
ladders.

## What it says

- **Throughput: the 9555P matches the 9575F** (7.7–7.9 vs 8.0 jobs/s). Both are one socket of 64 Zen 5 cores.
  Vera stays ~3.3× ahead (26 jobs/s on 352 threads).
- **Idle-image startup: the 9555P ties the 9575F at 1,000** (create p50 ~1.0 s, all ready ~2.1 s) and has a slightly
  lower p50 at 2,000 (2.1 vs 2.4 s), with a wider p95 (3.5–5.2 vs 3.6 s). Both are ahead of Vera (p50 1.6 s at 1,000,
  2.9 s at 2,000).
- **Agent-image startup: the 9555P is 2–3× faster than the 9575F.** At 1,000, all ready takes 8.2–8.5 s against
  18.8–19.1 s; at 2,000 the create p50 is 7.6 s against 19.6 s. It is also the only cell faster than Vera here.
- **The agent-image gap to the 9575F is not explained yet.** The software and recipe are identical, and so is the CPU
  family. The candidates are the host-level differences in the table above. The cpu.weight drop-in that ranks the
  runner above the guests, and the 2048 MaxAckPending, both change how the 9575F schedules the agent entrypoints
  against the create path. A run on the 9575F with those two reverted, or a per-step run on both hosts, would locate it.
- **The 9555P has no failures at all**, including the level-2,000 ladder where the 9575F and Vera each lost one job
  to the proxy dial timeout.

## Changes made to the host (all in `/etc/rlp/HOSTCHANGES`, backups kept)

- Backed up the Sep 15 binaries, env files and unit to `/etc/rlp/backup-sep15-20261020_075823/`; a DB dump is in
  `/mnt/data/backup/`.
- Cleaned up Sep 15 leftovers: killed 14 idle Firecrackers and marked 81 stale sandbox rows deleted.
- Installed the bench build and harness, and aligned the cell config (above). **`RLP_SNAPSHOTS` was unset before, so
  every sandbox in the Sep 15 run cold-booted.** The Sep 15 atl1 numbers are not comparable with this baseline.
- The schema upgrade to `f0611fa13` needs a parent in the region hierarchy: added the macro region `atl1-cell` and
  rewrote `/etc/rlp/regions.json` in the 9575F's format (`macro-fix.sh`).
- This API rejects the legacy `rlp_` key. Minted a current-format key with `rlp-api mint-key` for the same project and
  permissions (`mint.sh`). The old key is kept as `bench-api-key.legacy-rlp`.
- Restored the priority-95 routing rule for the sandbox subnet (its oneshot service had lost it). Set an open-files
  limit of 1,048,576 in `limits.d` (scripts must still call `ulimit -n 1048576`, because the SSH session's hard limit
  is 524,288). Added a uv Python alias link.
- Removed 1,408 orphaned pool cgroups left by the previous runner process.
- Host left idle with the fixes ON and 0 sandboxes.

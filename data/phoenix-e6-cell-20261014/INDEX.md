# phoenix-e6 bench cell — results, 2026-10-14

OCI Phoenix `BM.DenseIO.E6.Ax.192` (`<turin-host>`, user `ubuntu`): AMD EPYC 9J45 "Turin",
2 × 96 cores / 384 threads, 2,267 GiB, 12 × 6.8 TB NVMe (one in use), 2 × 200 Gbit.
Built as a standalone single-host Daytona cell with the **same software as the HQ Vera cell**
(`f0611fa13` + EROFS-4k + `RLP_FC_SOCK_WAIT_MS` + inactive `RLP_FC_SMT`), so its numbers are
comparable to the Vera and EPYC 9575F series.

## Headline numbers

| measurement | result |
|---|---|
| 1,000 sandboxes ready, idle image, whole box | **7.95 / 7.96 s** |
| 2,000 sandboxes ready, idle image | **23.2 s** |
| 1,000 ready, agent image, whole box (startup *under load*) | 7.90 / 8.01 / 7.97 s |
| 2,000 ready, agent image, whole box | 22.3 / 21.9 s |
| highest clean density (waves of 2,000, zero failures) | **8,000 concurrent** |
| highest density observed alive | **9,750** (9,946 firecracker processes) |
| what stopped it | the runner's heartbeat, then the lost-sweep — **not** the hardware |

At 8,000 live: 406 GiB of 2,267 used, CPU reservation 200 of 364.8, scratch 500 GiB of 6.9 TB.

**Read `FINDINGS.md` before quoting any of these.** Two numbers above are startup-*under-load*, not
startup (the agent image runs a CPU-bound entrypoint in every sandbox — methodology §0), and every
density ceiling below 9,750 was a configured limit that was found and lifted, not a property of the
machine.

## What is in here

| path | contents |
|---|---|
| `FINDINGS.md` | the full record: cell spec, all results, the ceiling analysis, and the open items. The primary document |
| `RUNBOOK.md` | how to run a benchmark on this cell (preflight, clients, cleanup, placement, knobs, paths) |
| `benchmark-methodology.md` | the cross-platform methodology doc, at the revision this work used, with the phoenix placement and client findings folded in |
| `runs.tgz` | every run: 208 files — per-sandbox JSONL, client logs, preflight records, resource samples, run logs. Dirs: `pin-ab-*` (placement A/B), `burst2k-*` (1k/2k), `ladder-*` (burst ceiling), `waves-*` (holding ceiling) |
| `evidence/` | the log and DB lines behind the three claims that are not self-evident from the run logs |
| `config/` | cell configuration (secrets redacted), `HOSTCHANGES`, and the two tools the methodology requires (`bench-preflight.sh`, `mpfleet.py`) |
| `scripts/` | every script used, in the order they were run (below) |
| `SHA256SUMS` | checksums for `runs.tgz`, `FINDINGS.md`, `RUNBOOK.md` |

### Rebuilding this cell from scratch

`scripts/` in execution order: `ph-hostprep.sh` (single-NVMe `/mnt/data`, sysctls, udev, limits) →
`ph-build.sh` (x86_64 binaries + pinned Firecracker) → `ph-pull.sh` (run **on the 9575F**: guest
kernel, initdisk, layers, `rlp-rs-0.4.1` daemon layer, harness, SDK) → `ph-cell.sh` (Postgres,
NATS, API, runner, proxy, region, bench key) → `ph-harness.sh` + `ph-harness2.sh` (client, target
registration, tooling) → `ph-warm.sh` (template warmup + smoke).

Then the experiments: `ph-pin-ab.sh` (placement), `ph-2k.sh` (1k/2k), `ph-capacity.sh` (raise
netns pool / max-live / subnet), `ph-ladder.sh` (burst ceiling), `ph-waves.sh` (holding ceiling),
`ph-capraise.sh` (bench-only API cap patch), `ph-scratchfix.sh`, `ph-clean.sh` /
`ph-orphanclean.sh` (teardown, the latter for the orphan recovery), `meth-patch.py` (methodology
update).

### Evidence files

| file | proves |
|---|---|
| `api-runner-lost.txt` | `20:27:38 runner phoenix-e6-1 marked lost` — the moment the control plane lost a runner that was healthy and serving 8,000 sandboxes |
| `runner-capacity-and-adopt.txt` | the adopt-verify batch cap (`adopted=9822 cap=4096`) going permanently inconclusive above 4,096 VMs/host |
| `scratch-gate-6742.md` | the 1 GiB-per-sandbox scratch reservation gate, its arithmetic, which runs hit it — and a note that its journal window has rotated out |
| `vms-by-status-final.txt` | the final clean state |

## State of the box as left

Clean and idle: 0 firecrackers, netns pool 6,200, runner `online`, 2,197 GiB free, all three
services active. The cell carries **two deliberate, logged deviations from stock** (both in
`config/HOSTCHANGES`): an API built with `CREATE_MAX_QUEUE_SECS_CAP` 60 → 900, and
`RLP_MAX_QUEUED_CREATES=40000`. Both exist so a density ladder measures the machine instead of a
constant; **neither belongs on a fleet host**. `/mnt/data` is one NVMe, matching HQ Vera's
single-disk layout — the other 11 drives are unused and the OCI RAID10 was deliberately torn down.

## Not done

- No GitHub issue filed yet for the density-induced runner-lost → lost-sweep orphaning, which is
  the most consequential thing found here and is very likely the mechanism behind the earlier
  Phoenix / RedSwitches / Vultr "runner crashed, thousands of leftover firecrackers" reports.
- Nothing is committed to git.
- The agent-throughput ladder (jobs/s plateau), the other published Vera number, has not been run
  on this cell.

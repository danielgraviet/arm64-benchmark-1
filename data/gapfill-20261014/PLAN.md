# Gap-fill plan: HQ Vera vs Turin (phoenix-e6) vs Graviton5

**Status:** defined, not run (2026-10-14). All three hosts were being driven by other sessions when this was written.

**Goal:** a complete, like-for-like comparison table that shows where Vera is ahead and where it is not.
The table needs every cell measured by **one method on all three hosts**. Today the startup cells mix
client shapes (1 vs 16 processes, client pinned vs floating) and images, and several cells are empty.

## Hosts

| | HQ Vera | Turin (phoenix-e6) | Graviton5 |
|---|---|---|---|
| ssh | `sshpass -e ssh -p 2228 daytona@localhost` (reverse tunnel) | `ubuntu@<turin-host>` | `ubuntu@<graviton5-host>` |
| `HOSTP` / harness target | `vera` / `vera` | `phoenix` / `phoenix-e6` | `graviton5` / `graviton5` |
| CPU | 2 × 88 cores, 2 threads/core (352) | 2 × 96 cores, 2 threads/core (384) | 1 socket, 192 cores, 1 thread/core, 2 NUMA nodes |
| Memory | 1,478 GiB | 2,267 GiB | 754 GiB |
| Host page size | 64 KiB | 4 KiB | 4 KiB |
| `UNPIN` | `0-351`, mems 0-1 | `0-383`, mems 0-1 | `0-191`, mems 0-1 |
| `HALF` | socket 0: `0-87,176-263`, mems 0 | socket 0: `0-95,192-287`, mems 0 | node 0: `0-95`, mems 0 |
| Power telemetry | ACPI "AP Power socket N" (hwmon), both sockets | RAPL package energy (no DRAM) | none (AWS) |

Only `rlp.slice` and `rlp.slice/vms` are pinned. The API, Postgres, NATS and the benchmark client always float.

## What is missing

| Measurement | Vera | Turin | Graviton5 | Run by |
|---|---|---|---|---|
| **S. Startup**: {UNPIN, HALF} × {`alpine:3.20` idle, agent image} × {1k ×3, 2k ×2}, `mpfleet.py` 16 procs | 1k exists (2 reps per cell, outliers, client pinned to the other socket); **2k missing** | 1k agent + 1k/2k idle UNPIN exist; **HALF idle and agent 2k missing** | agent 1k exists; **idle and all 2k missing** | `gapfill.sh` phase S, rerun in full everywhere so every cell has the same client |
| **T. Throughput ladder, UNPIN**, c = 44 … 2000 | only 176/352/704 | **missing** | done (22.96/s at c=2000) | phase T |
| **T. Throughput ladder, HALF**, c = 44 … 1408 | only 176/352/704 | **missing** | done to 1056; 1408 running in its session | phase T |
| **Power and clock during T** | missing | missing | not available | sampler in phase T |
| **C. Idle-density ceiling**, 3000 → 6000, stop at first short level | **missing** | running in its session (`ladder-20261014_140050`) | **missing** | `capacity.sh raise` + phase C |
| Graviton5 64 KiB-page A/B | — | — | planned in its session | after S and C on 4 KiB |

## Order per host

Each host runs only after its other session has stopped (one operator per box). The script waits for
5 quiet minutes and takes `/tmp/gapfill.lock`, but other sessions do not take that lock.

1. **Vera**: `PHASES="S T"` (~2.5 h) → `CEIL_CIDR=<free /18> capacity.sh raise` (~20 min, may drop the reverse
   tunnel) → `PHASES=C` → `capacity.sh restore`.
2. **Turin**: `PHASES="S T"` (~2.5 h). Ceiling comes from its own session. Then restore caps to 2100/3000/`/20`
   if that session has not.
3. **Graviton5** (its session rebooted into the 64 KiB kernel at 14:19 UTC, so "4 KiB first" now means switching
   back with a plain reboot, or accepting 64 KiB and labeling it): update `~/arm64-benchmark-1/mpfleet.py` (the
   copy there lacks `MPFLEET_IMAGE`) → `PHASES=S` (~40 min) → `capacity.sh raise` → `PHASES=C` →
   `capacity.sh restore` → hand back to its session for the 64 KiB A/B.

```bash
# copy the four files to ~/gapfill/ on the host, then for example:
cd ~/gapfill && HOSTP=vera PHASES="S T" setsid nohup bash gapfill.sh > gapfill.out 2>&1 < /dev/null &
```

Output: `/mnt/data/bench/gapfill-<host>-<stamp>/` with `log`, `results.tsv` (one row per rep or level), per-run
JSONL, journals counts, and `*.samp` (power W, GHz, firecracker count, MemAvailable).

## The table this produces

| Row | Source | Why it matters for Vera |
|---|---|---|
| Platform startup, idle 1k / 2k, UNPIN and HALF | S | Vera's startup lead disappeared with an idle image on the 9575F; this confirms it against Turin and Graviton5 |
| Startup under load, agent 1k / 2k | S | Shows how fast each host gets through the entrypoint storm |
| Throughput ceiling, UNPIN and HALF (jobs/s) | T | Vera's strongest known result (26.6/s) |
| Jobs/s per physical core and per hardware thread | T, derived | Separates "more cores" from "faster cores" |
| Single-job latency at c=44 (p50 duration) | T | Per-core speed with no contention |
| Latency at c=704 and c=2000 (p50 / p99 duration) | T | Behavior when packed |
| Clock under full load (GHz) | T sampler | The 9575F lost 24 % of its clock when packed, OCI Vera 6 % |
| Jobs/s per watt (Vera vs Turin only) | T sampler | Vera AP power includes more than the RAPL package; label the scope |
| Max idle sandboxes before the first failure | C | Memory/netns bound; Turin's 2.2 TB likely wins |
| Failures, socket-wait timeouts, self-cordons | all | Reliability under the same load |

## Caveats to carry into the table

- Vera runs the 64 KiB-page host kernel and `preempt=none`; Graviton5 runs 4 KiB and voluntary preemption
  (the AWS kernel cannot switch); Turin runs 4 KiB.
- Guest kernels differ by architecture: x86 `vmlinux-6.8.12-rlp3`, arm64 `6.12.34-rlp1`.
- Turin's idle-image startup (≈ 8 s for 1k) did not drop to ≈ 4 s like Vera and the 9575F. That is unexplained
  and is a separate investigation, not a table row.
- Power scopes differ (Vera AP module vs AMD package without DRAM). Graviton5 has none.

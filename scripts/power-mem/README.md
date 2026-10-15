# Jobs per watt + memory-bandwidth workload — run kit (2026-10-15)

Two tests that the consolidated report (`gapfill-20261014/vera-benchmark-report-20261015-v2.pdf`, section 9) lists as open.
**Status: run on HQ Vera, the EPYC 9575F and Graviton5 on 2026-10-15; Turin has the power baseline but not the memory
ladder.** Results and the analysis write-up are in `data/vera-hq-cell-20261014/power-mem-20261015/RESULTS.md`,
`data/graviton5-cell-20261014/FINDINGS.md` (section 8) and `data/phoenix-e6-cell-20261014/FINDINGS.md` (power section).

| file | what |
|---|---|
| `power-sampler.py` | every 2 s: all power domains the host exposes (Vera ACPI meters: Total / AP / CPU rail / SOC rail / DRAM per socket; x86 RAPL package per socket; BMC wall power via `ipmitool dcmi` if it works), **busy-core clock** (mean freq of CPUs ≥ 90 % busy — the same method on every host), fc count, MemAvailable |
| `power-ladder.sh` | idle baseline (180 s), then the published dense agent ladder (levels 44 176 352 704 2000) with the sampler → `report.md` |
| `memtest.c` | STREAM-style triad `a = b + s·c` for one vCPU, 3 × 2²⁴ doubles (384 MiB), runs for N seconds, prints JSON |
| `memfleet.py` | creates N sandboxes from `$MEMFLEET_IMAGE`, compiles memtest inside each (not timed), then runs all N at the same instant |
| `mem-ladder.sh` | memfleet at 1 8 32 64 128 176 256 352 sandboxes (skips levels > nproc), 2 reps × 30 s, sampler on → `report.md` |
| `common.sh` | host profiles (`HOSTP=vera|phoenix|epyc9575|graviton5`), cleanup, preflight gate, idle wait, state record |
| `power-report.py`, `mem-report.py` | analysis (also run automatically at the end) |

Results land in `/mnt/data/bench/{power,mem}-<host>-<stamp>/` (log, host-state.txt, JSONL, `.samp`, `report.md`).

## Preconditions (every host)

- One operator: nobody else on the box (`who`, `tmux ls`, no `main.py`/`mpfleet.py`/`memfleet.py`/`gapfill.sh`), **0 firecrackers**
  (the scripts wait for 3 quiet minutes and will wait forever if stale sandboxes are left — clean them first).
- Reference state from 2026-10-14/15: create-path fixes ON (`bench-preflight` prints `create_path_fixes ON`), whole box unpinned
  (`rlp.slice` = all CPUs; the scripts abort otherwise), same binaries as the baselines.
- Copy the kit: `scp -r scripts/power-mem <host>:~/power-mem` (run it from there; it uses the harness venv
  `$BD/.venv/bin/python` directly, so it works as root on the 9575F).
- **Use `MEMFLEET_IMAGE=buildpack-deps:bookworm`.** `gcc:14` kernel-panics the guest on the `f0611fa13` bench build:
  its `GPG_KEYS`/`GCC_MIRRORS` values contain spaces and the old guest init writes them unquoted into `/.rlp-launch`,
  so PID 1 exits. Fixed upstream in `98a1be351` (daytona/rlp#1554). Measured difference between gcc 14.4 and 12.2 on
  this kernel: under 0.5 %. Use the same image on every host.
- Optional, wall power: `/dev/ipmi0` exists on HQ Vera and the 9575F. `ipmitool dcmi power reading` failed on Vera; the 9575F has no
  `ipmitool` installed (installing it is a host change — log it in `/etc/rlp/HOSTCHANGES`). OCI Turin and AWS Graviton5 expose no BMC.

## What each host runs

| host | power-ladder | mem-ladder | ≈ time |
|---|---|---|---|
| HQ Vera | `HOSTP=vera bash power-ladder.sh` | `HOSTP=vera bash mem-ladder.sh` | 40 + 45 min |
| EPYC 9575F | `HOSTP=epyc9575 bash power-ladder.sh` (2,000 level ≈ 35 min alone) | `HOSTP=epyc9575 bash mem-ladder.sh` (levels to 128) | 75 + 30 min |
| Turin | `HOSTP=phoenix IDLE_ONLY=1 bash power-ladder.sh` (its 10-15 ladder already has RAPL package power) | `HOSTP=phoenix bash mem-ladder.sh` | 5 + 45 min |
| Graviton5 | — (no power telemetry on AWS) | `HOSTP=graviton5 bash mem-ladder.sh` (levels to 176) | 35 min |

Launch detached, e.g. `cd ~/power-mem && HOSTP=vera setsid nohup bash power-ladder.sh > power.out 2>&1 < /dev/null &`, then
`mem-ladder.sh` after it finishes (they share a lock and refuse to overlap).

## Reading the results

- **Jobs per watt:** use the plateau levels (352, 704, 2000). `processor_w` = Vera "AP Power" (both sockets) vs AMD RAPL package (both
  sockets); neither includes DRAM. `module_w` = Vera "Total Power", which includes the on-module LPDDR. **Confirm what Vera's AP and
  Total domains cover before quoting**; the definitions are NVIDIA's, not ours. Report energy per job (J/job) and jobs/s per kW, plus
  idle power. Preliminary Turin figure from its existing ladder: ≈ 970 W package at the plateau → **22.7 jobs/s per kW, ≈ 44 J per job**.
- **Clock under load:** `busy GHz` at level 44 vs the plateau — the same method on every host, replacing the mixed −3/−6/−21/−24 % figures.
- **Memory bandwidth:** `aggregate GB/s` = sum of the concurrent per-sandbox triad rates, valid when `start skew` ≪ 30 s. The c=1 row
  is single-core bandwidth inside a sandbox; the curve's plateau is how much memory bandwidth sandboxes can extract from the host. Also
  report GB/s per W. STREAM convention (write-allocate not counted).
- Caveats to carry: guests are 1 vCPU, so bandwidth is reached only by many sandboxes (the product's shape); host page size differs
  (Vera 64 KiB); the first create builds a template (the warm-up step absorbs it).
- **Guest clocks are not host clocks.** Arm64 snapshot clones keep the template's wall clock (daytona/rlp#767), so
  `start_skew_s` / `overlap_s` from memtest's own timestamps are meaningless there. Use memfleet's host-side
  `t_exec_send` / `t_exec_done` (see `data/vera-hq-cell-20261014/power-mem-20261015/mem-power.py`).

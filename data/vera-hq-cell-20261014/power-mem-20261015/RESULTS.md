# Jobs per watt and memory bandwidth: HQ Vera vs EPYC 9575F (2026-10-15)

Kit: `data/power-mem-20261015/` (SHA256SUMS verified on both hosts; scripts unchanged). Both hosts in the reference
state of the 2026-10-14 baselines: same binaries (Vera runner `0fd55bab4ad6` / api `1648ab971fe5`; 9575F runner
`739fc73a116d` / api `93fa5e93bf20`), create-path fixes ON, `rlp.slice` unpinned (all CPUs), 0 firecrackers, one operator.

**One approved recipe deviation:** the memory ladder ran with `MEMFLEET_IMAGE=buildpack-deps:bookworm` (gcc 12.2)
instead of `gcc:14`. `gcc:14` sets ENV values containing spaces (`GPG_KEYS`, `GCC_MIRRORS`); the bench build's guest
init writes them unquoted into `/.rlp-launch`, the shell rejects `export 90AA…`, PID 1 exits and the guest kernel
panics. That defect (#1554) is fixed on `main` in `98a1be351` (2026-10-02), after the bench build's base `f0611fa13`.

Result directories (raw data in `vera-power-mem.tgz`, `epyc9575-power-mem.tgz`):

| | HQ Vera | EPYC 9575F |
|---|---|---|
| power ladder | `/mnt/data/bench/power-vera-20261015_130420` | `/mnt/data/bench/power-epyc9575-20261015_130401` |
| memory ladder (valid run) | `/mnt/data/bench/mem-vera-20261015_143002` | `/mnt/data/bench/mem-epyc9575-20261015_150022` |
| failed memory attempts (kept as record) | `mem-vera-20261015_133050` (gcc:14) | `mem-epyc9575-20261015_140704`, `_142638` (gcc:14 / no mkfs.erofs / Docker Hub limit) |
| extra telemetry | `vera-meters-*.tsv` (all hwmon meters, 2 s) | `ipmi-sdr-epyc9575-20261015_130401.tsv` (BMC SDR + DCMI, 10 s) |

## 1. What the power numbers measure

| scope | HQ Vera | EPYC 9575F |
|---|---|---|
| **processor_w** (kit) | "AP Power", both sockets | RAPL package (1 socket) |
| module_w | "Total Power", both sockets | — |
| wall_w | **not available**: DCMI fails, the BMC has no PSU/system sensor (only per-module CPU power) | BMC DCMI (`ipmitool`, installed for this run); agrees with the SDR "PW Consumption" sensor within 1% under load |

**What Vera's meters cover**, as far as it can be established:
- NVIDIA publishes definitions only for **Grace** ([Grace Performance Tuning Guide, Power Telemetry](https://docs.nvidia.com/grace-perf-tuning-guide/power-thermals.html)):
  the socket total ("Grace Power Socket N") is the *"total power of the socket, including DRAM power and regulator
  loss"*; "CPU Power" is the CPU rail *including* regulator losses (≈15% of the TDP limit); "SysIO" is the SoC rail.
  For a comparison with AMD it says to use the CPU rail **minus regulator losses**, because AMD package power
  excludes regulator losses and DRAM. No Vera edition of the document is public.
- Vera's ACPI tables (`SSDT6.dsl`/`SSDT7.dsl`) name the meters but declare **no metered devices** (`_PMD` empty for
  all). The only meter with an enforceable hardware limit is **"Total Power"** (`HLIM=1`, `power1_cap` =
  600 W): it is the domain the 600 W per-socket cap applies to.
- Measured relations (side logger), per socket: **AP ≈ CPU rail + SOC rail + DRAM + 26–40 W**; **Total ≈ AP +
  30–47 W**. Vera also exposes **"CPU Rail Output Power"**: output ÷ input is **0.84–0.89 under load** (regulator
  efficiency) and 0.3–0.5 at idle (large fixed regulator loss).

So: **Vera "AP" ≈ CPU + SoC + on-module LPDDR + other module rails, including regulator losses; Vera "Total" ≈
the whole socket module, the capped quantity.** Neither is like-for-like with AMD's package power, which excludes
regulator losses and DRAM. The closest Vera analogue is **CPU Rail Output + SOC rail**, reported below as a third
scope (from the side logger, not the kit).

## 2. Idle power

| | processor | module / wall | DRAM |
|---|---|---|---|
| HQ Vera | **225 W** (AP, both sockets) | 282 W Total (module); wall n/a | 17 W |
| EPYC 9575F | **54 W** (RAPL package) | **133 W** wall (DCMI; SDR sensor 147 W) | not exposed |

## 3. Jobs per watt (dense agent ladder, 0 failures on both hosts)

| level | | jobs/s | processor W | jobs/s per kW (processor) | J/job (processor) | module/wall W | jobs/s per kW (module/wall) | J/job (module/wall) | busy GHz |
|---|---|---|---|---|---|---|---|---|---|
| 352 | Vera | 26.29 | 1,108 (AP) | **23.7** | **42.1** | 1,185 (Total) | 22.2 | 45.1 | 3.37 |
| 352 | 9575F | 7.93 | 374 (pkg) | **21.2** | **47.2** | 692 (wall) | 11.5 | 87.3 | 3.65 |
| 704 | Vera | 25.52 | 1,079 | **23.6** | **42.3** | 1,159 | 22.0 | 45.4 | 3.37 |
| 704 | 9575F | 8.03 | 379 | **21.2** | **47.2** | 700 | 11.5 | 87.2 | 3.66 |
| 2000 | Vera | 26.25 | 1,109 | **23.7** | **42.3** | 1,192 | 22.0 | 45.4 | 3.37 |
| 2000 | 9575F | 8.02 | 382 | **21.0** | **47.7** | 717 | 11.2 | 89.4 | 3.69 |

Vera in the AMD-package-like scope (CPU Rail Output + SOC rail, side logger): **911 / 806 / 863 W at 352 / 704 /
2,000 → ≈ 29–32 jobs/s per kW, ≈ 32–35 J/job**. Vera's wall power is unknown, so a whole-system comparison is not
possible; Vera's "Total" excludes fans, NICs, storage and PSU loss, which the 9575F's wall figure includes.

**Clock under load** (busy-core method, same on both):

| | level 44 | packed (352–2,000) | change |
|---|---|---|---|
| HQ Vera | 3.39 GHz | 3.37 GHz | −0.6% |
| EPYC 9575F | 4.33 GHz | 3.65–3.69 GHz | **−15%** |

**Both CPUs run at their power limit at the plateau.** Vera's "Total" sits at a mean 546–591 W per socket and peaks at
605–606 W against the 600 W cap from 352 sandboxes up. The firmware's power-cap throttle counter on socket 0 rose
~21 M samples ×1000 during the ladder, yet the measured clock does not drop. At 44 and 176 sandboxes Linux puts the
work on socket 0, which hits the cap while socket 1 idles. The 9575F's package reads ~400 W already at 44 sandboxes
(its power limit), which is where its 15% clock drop comes from.

## 4. Memory bandwidth (STREAM-style triad, 384 MiB per sandbox, 1 vCPU each, 2 reps × 30 s)

| sandboxes | Vera GB/s (rep 1 / 2) | Vera processor W | Vera GB/s per W | 9575F GB/s (rep 1 / 2) | 9575F processor W | 9575F GB/s per W |
|---|---|---|---|---|---|---|
| 1 | 72.5 / 72.1 | 234 | 0.31 | 45.1 / 47.1 | 103 | 0.45 |
| 8 | 550.8 / 570.3 | 338 | 1.66 | 262.4 / 260.9 | 204 | 1.28 |
| 32 | 1,019 / 1,015 | 469 | 2.17 | 299.8 / 299.7 | 280 | 1.07 |
| 64 | 1,744 / 1,853 | 734 | **2.45** | 301.5 / 302.1 | 341 | 0.89 |
| 128 | 2,124 / 2,125 | 882 | 2.41 | 305.2 / 305.1 | 366 | 0.83 |
| 176 | 2,099 / 2,108 | 1,003 | 2.10 | — (> 128 threads) | | |
| 256 | 2,070 / 2,068 | 1,065 | 1.94 | — | | |
| 352 | 1,357 / 1,406 | 961 | 1.44 | — | | |

- **Plateau: Vera ≈ 2.1 TB/s (128–256 sandboxes), 9575F ≈ 0.30 TB/s (from 32 sandboxes up) — about 7×.**
- **Single sandbox:** Vera 72 GB/s, 9575F 46 GB/s.
- **GB/s per processor W at the plateau:** Vera 1.9–2.4 vs 9575F 0.83–1.07 (scopes differ as in §1; Vera's AP
  includes the LPDDR, which draws 79–81 W at the plateau).
- At 176–256 sandboxes Vera's module power is 1,200–1,205 W, the power cap again. At 352 (every hardware thread)
  bandwidth drops to 1.4 TB/s.

**Measurement notes**
- **Vera's power column in the kit's `report.md` is `nan`.** `memtest` stamps its window with the guest's wall clock,
  and on Vera that clock is 84–836 s behind the host, growing with template age (daytona/rlp#767). The power figures
  above come from `report-host-window.md` (script `mem-power.py`), which uses memfleet's host-side exec timestamps;
  host send skew ≤ 0.04 s, so runs overlapped. The 9575F's guest clock is correct (offset 0–1 s) and its kit report
  matches.
- **No wall-power figure for the memory runs.** The sampler reads DCMI every 10 s, so a 24 s window holds ~2 lagged
  readings; the values are erratic (135–549 W at the same load).

## 5. Failures

| | power ladder | memory ladder (valid run) |
|---|---|---|
| HQ Vera | 0 | 7 of ~1,042 sandboxes, all during setup (`bad gateway: sandbox … not available`), none during measurement |
| EPYC 9575F | 0 | 0 |

## 6. Problems hit and host changes

- **Vera:** the `gcc:14` attempt self-cordoned the runner after 5 failed boots. Cleared with a runner restart (fix
  drop-ins unchanged). My diagnostic `gcc:14` sandbox was stuck in `deleting` and was marked deleted in the database.
- **9575F:** installed `/usr/local/bin/bench-preflight` (the kit's `gate()` calls it), `ipmitool` (wall power) and
  `erofs-utils`. The bench build converts new image layers with `mkfs.erofs`, which was missing, so every new image
  failed on this host. Failed creates were retried until they exhausted Docker Hub's anonymous pull limit, and the
  stopped run left an orphaned sampler holding the kit's lock. Fixed by one cached warm create, killing the orphan, and
  marking stuck `deleting` rows (failed creates, no Firecracker) deleted.
- Every change is logged in `/etc/rlp/HOSTCHANGES` on both hosts. Both are left idle in the reference state
  (preflight PASS, `create_path_fixes ON`).

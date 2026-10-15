# Graviton5 (m9gd.metal-48xl) findings, 2026-10-14

The software is identical to HQ Vera (same binary checksums). Runs are 1,000-sandbox create-ready bursts (bench recipe) plus the
published dense agent ladder (n=45, seed 42, -E 8, hold-then-exec, cpu 0.025/max 1, mem 0.0625/max 4, disk 16 MiB, pool 512).
Raw data is in `bench-results.tgz` (`suite-4k-*`, `suite-64k-*`, `memprobe-*`).
Layouts: UNPIN = sandboxes on both NUMA nodes (192 cores); PIN-N0 = node 0 only (96 cores, its own memory). The control plane is never pinned.

## 1. One node vs both (4 KiB kernel)
- Startup, 1k: both nodes 9.4 s median (7.1–13.8) vs one node 15.3 s (14.8–18.6). **Pinning is slower**, the reverse of Vera
  (Vera: one socket 8.4–10.6 s vs both 20–23 s). Crossing nodes on Graviton5 costs nothing visible; halving the cores does.
- Throughput: both nodes plateau at **22.9 jobs/s**, one node at **11.9 jobs/s**, so scaling across nodes is exactly linear.
- Zero failures through c=2000 (both nodes) and c=1408 (one node). 0 socket timeouts and 0 self-cordons in every run.

## 2. Client processes (control plane)
Accept p50: 1 proc 4.3 s → 4 procs 0.49 s → 8 procs 0.24 s → 16 procs **0.12 s** (Vera: 0.23–0.50 s at 16). All-ready does not
improve (7.7 → 9.8 s): as on Vera, a 1k burst is bounded by the guest side, not the API. Specifically, the guests are running
the image entrypoint (§5.1).

## 3. 4 KiB vs 64 KiB pages (same kernel 6.17.0-1017-aws, one reboot)
| | 4 KiB | 64 KiB |
|---|---|---|
| 1k startup, both nodes (median, 6 reps) | 9.4 s | 9.9 s |
| 1k startup, one node | 15.3 s | 18.6 s |
| ladder plateau, both nodes | 22.9 /s | 23.2 /s (+1.5%) |
| ladder plateau, one node | 11.9 /s | 12.1 /s |
| job duration at light load (c=44–176) | 6.65–6.72 s | 6.63–6.73 s |
| `echo ready` probe p50 | ~50 ms | ~28 ms |
| host RAM per idle sandbox (500 kept clones; RssAnon / node delta) | 129 / 173 MiB | 139 / 190 MiB (+8–10%) — **corrected, see §5** |
| host RAM per sandbox under agent load (c=704) | 215 MiB | 233 MiB (+8%) |
| one node, c=1408 | 0 failures | **node 0 out of memory**: 67 firecrackers, 9 postgres processes and the harness were OOM-killed |
- 64 KiB pages do not make the CPU work faster (≤1.5%). They cost about **8% more host memory per sandbox**, which is enough to
  push one 377 GiB node past its limit at 1,408 sandboxes (≈1408 × 233 MiB vs 1408 × 215 MiB).
- Caveat: the 64 KiB suite ran on a template snapshot minted under the 4 KiB kernel (templates live in `scratch/snapshots`, not `templates/`).

## 4. Comparison with the published ladders (one Vera socket; AMD whole chip)
| host | cores | light-load job | plateau jobs/s | jobs/s per core |
|---|---|---|---|---|
| Vera, socket 0 (88 c / 176 threads) | 88 | 5.9 s | ~13.0 | 0.148 |
| **Graviton5, both nodes** | 192 | 6.65 s | **22.9** | 0.119 |
| Graviton5, one node | 96 | 6.65 s | 11.9 | 0.124 |
| EPYC 9575F | 64 | 6.7 s | ~8.1 | 0.127 |
| EPYC 9755 | 128 | 7.1 s | ~11.0 | 0.086 |
Vera is ~11% faster per job and ~20% higher per core. Graviton5 wins on total throughput through core count (2.2× Vera's socket),
and it holds 2000 with zero failures (Vera's published 2000 point had 53–627 failures).
Caveat: the published Vera/AMD ladders used a 1 GiB disk; these runs used 16 MiB (disk size was ruled out on the 9575F).

## Incidents
- 64 KiB, one node, c=1408: the node-0 OOM also killed the user session, so the suite's trap never ran. rlp.slice stayed pinned and
  1,237 firecrackers were orphaned. Recovered with an unpin, a runner restart and `g5-netreset.sh`. Postgres auto-recovered.

## 5. Investigation (follow-up, same day)

### 5.1 The 1k startup burst is dominated by the benchmark image's own entrypoint
This reproduces on Graviton5 what was found on HQ Vera and the 9575F earlier the same day (`docs/benchmark-methodology.md` §0:
alpine 1k = 4.0–4.2 s on both hosts).
- Templates are *pre-entrypoint* snapshots, so every clone runs the image CMD after resume:
  `python -m workload.agent --n 30 --seed 42`. That costs **~4.1 CPU-s per sandbox** (one clone: 4.18 s of FC CPU in 3 s, then idle).
- CPU accounting for a 1k burst (UNPIN, 9.2 s): host **191 of 192 cores busy**. Guests use **1,637 core-s**, and another 3,460 core-s
  follow in the next 20 s. Platform: runner 22, API 2, proxy 1, Postgres 3, client 14 core-s, i.e. **~28 ms of platform CPU per sandbox**.
- Same burst with `python:3.12-slim` (CMD exits at once): **1k all-ready in 3.8 s**, host 30% busy, guests 74 core-s.
- So the "1,000 sandboxes ready" numbers on every platform measure how fast the host chews through 1,000 concurrent agent
  episodes alongside the spawns, not platform startup. This is why startup scales with cores × per-core speed.
- The throughput ladder carries it too: each sandbox's entrypoint adds ~4 core-s against 8 jobs × ~7 core-s, about 7%, the same
  proportion on every platform.

### 5.2 Why pinning hurts here and helped on Vera
- Cross-node latency on Graviton5 (pointer chase, 2 GiB): local 129 ns, remote 156–168 ns → **1.2–1.3×**. The vanilla study
  measured 1.30× on Graviton5 and **3.08× on Vera** (129 → 399 ns).
- The burst is CPU-bound (5.1). With half the cores and near-free remote memory, pinning only removes capacity. Runner phases
  (journald boot-phases, 4 KiB): FC spawn p50 **14 ms unpinned vs 255 ms pinned** (p95 0.4 vs 2.1 s). The spawn is starved of CPU.
  On Vera the remote-latency penalty dominates instead.

### 5.3 Memory per sandbox: correction and breakdown
- **The earlier "2.3× on 64 KiB" was my measurement error.** That 64 KiB probe ran right after I had wiped the templates, so
  412 of 500 sandboxes cold-booted (full boot, no snapshot). Re-measured with clones: 139 vs 129 MiB RssAnon idle (+8%), and
  233 vs 215 MiB under agent load (+8%).
- One clone (4 KiB): 145 MiB RSS, of which 116 MiB is private CoW of the template memory and 26 MiB is shared page cache.
  85% of the private pages are fresh writes into pages that were zero in the template (guest RAM offsets 2.0–2.2 GiB).
  - `python:3.12-slim` clone: 46 MiB private. The agent image's entrypoint adds about 70 MiB (python, imports, page cache).
  - 64 KiB: 60 MiB (slim) and 127 MiB (agent) private, so the amplification is small because guest writes are clustered.
- The guest sees 4 GiB and uses about 143 MiB of it. Host RSS tracks what the guest touches after resume.

### 5.4 Per-core speed light vs packed (guest-cgroup PMU counters, published recipe)
| c | jobs/s | job p50 | core-s/job | effective GHz | IPC |
|---|---|---|---|---|---|
| 96 (half the cores) | 13.07 | 6.69 s | 7.34 | 3.30 | 5.31 |
| 352 (packed) | 22.68 | 13.40 s | 7.90 | 3.21 | 5.08 |
Graviton5 runs at a fixed 3.3 GHz and loses only ~3% clock and ~4% IPC when packed (9575F: −24% clock; OCI Vera: −6%).
Its per-job gap to Vera is single-thread speed (6.65 s vs 5.9 s at light load); both hold that speed under full load.
core-s/job includes each sandbox's entrypoint (5.1), so the pure job is about 6.8 core-s.

### Incidents during the investigation
- None. The host was rebooted 64 KiB → 4 KiB for the memory A/B; it is back on 4 KiB, unpinned, with no sandboxes.

## 6. Rerun with the four create-path fixes (#3260, #3261, #3265, #3269), same recipe as the HQ Vera rerun

- Build: runner **`0fd55bab4ad6`**, rebuilt on this host with go1.27.2 from the HQ Vera bench tree and byte-identical to
  Vera's patched runner. API: `f0611fa13` + `patches/api-backlog.diff` (`bc21226c839b`; Vera's is `1648ab971fe5`, a different
  toolchain build of the same source). Stock binaries are kept as `*.bak-prepatch`.
- Arms are the same binaries with the flags OFF or ON. ON = `RLP_INITDISK_MODE=nofsync RLP_CGROUP_POOL=1400 RLP_NEIGH_PERMANENT=1` +
  `RLP_API_LISTEN_BACKLOG=4096`. Script: `scripts/g5-bench-fixes.sh` (Vera's `bench-fixes.sh` with the target changed). The client is
  `mpfleet.py --procs 16 --count 1000`, unpinned. Data: `fixes-bench.tgz`.
- The first attempt's ON arm applied only the API flag: this host had no `rlp-runner.service.d/`, so the drop-in write failed
  silently. Its OFF rows are valid and used below. ON was rerun after the fix, and the script now aborts if the runner flags don't
  apply (`README-ABORTED` marks the first dir).

### Startup, 1,000 sandboxes (3 reps each)
| | OFF | ON |
|---|---|---|
| idle image (alpine) all-ready | 3.57 / 3.60 / 3.63 s | **2.32 / 1.68 / 7.63 s** |
| idle image create p50 / p95 | 1.46–2.18 / 3.11–3.55 s | **0.81–0.90 / 1.54–1.56 s** |
| agent image all-ready | 10.10 / 11.77 / 11.83 s | 10.11 / 10.79 / 12.31 s |
| agent image create p50 / p95 | 3.45–3.53 / 9.42–9.49 s | 5.43–5.49 / 7.48–11.61 s |
| API listen-queue overflows (idle) | 0–143 per burst | 0 |
| failures | 0 | 0 |
- With an idle image the fixes halve startup: p50 0.85 s vs ~2.2 s, p95 1.55 s vs ~3.4 s, all-ready 1.7–2.3 s vs 3.6 s.
- ON idle rep 3's 7.63 s all-ready comes from **5 sandboxes with a 5.1–5.7 s toolbox wait** after resume. They happened at one
  moment, never in OFF arms (0 waits >1 s in 3,030 OFF idle creates). It is a new tail in 3,000 ON creates and not yet explained.
- With the agent image the fixes don't change all-ready. Faster spawns start the image entrypoints sooner, so the median
  sandbox waits longer for CPU (p50 3.5 → 5.4 s). The burst stays CPU-bound on the entrypoint (§5.1).
- Runner toolbox wait p50 rises from 3–7 ms to 28 ms with the fixes, because more guests resume at once (the bottleneck moves).

### Throughput ladder (published recipe, levels 176/352/704, unpinned)
| c | OFF jobs/s | ON jobs/s |
|---|---|---|
| 176 | 23.55 | 23.62 |
| 352 | 21.57 | 22.33 |
| 704 | 22.77 | 22.89 |
No change, as expected: throughput is in-guest work. 0 failures in both arms.

Host left as on Vera: patched binaries, every flag OFF (= stock behaviour), no sandboxes.

## 7. Gap-fill, 2026-10-15: 2,000-sandbox startup and the upper ladder, fixes ON

Fills the Graviton5 cells marked "not run" in `gapfill-20261014/vera-comparison-report-v2-20261014.pdf` and
`vera-benchmark-report-20261015.pdf`. The recipe is HQ Vera / 9575F `run2k.sh`, run as `scripts/g5-run2k.sh`:
`mpfleet.py --procs 16`, `--timeout 300`, client read timeout and job `--exec-timeout` 1,800 s, SDK polling 0.25 s ×1.5 → 2 s,
unpinned. Data: `gapfill-20261015.tgz` (`run2k-graviton5-20261015_063637`, including the runner journal).

**Pre-run audit and config.**
- No other operator since 2026-10-14 18:53. The create-path-breakdown session only ran read-only `journalctl` at 00:15–00:18.
- **unattended-upgrades ran at 06:03–06:09** (systemd/udev, libc, openssh, sudo, and a new `linux-image-7.0.0-1014-aws`,
  not booted). needrestart restarted `rlp-api` at 06:08. The running kernel and grub default are unchanged (6.17.0-1017-aws, 4 KiB).
  The apt timers and unattended-upgrades are stopped for benchmarking (runtime only, so a reboot restores them).
- Brought to the reference state of HQ Vera / 9575F: fixes ON persistently with `fixes-on.sh` (drop-ins
  `20-create-path-fixes.conf`), the harness `RLP_HTTP_READ_TIMEOUT_S` patch, and a preflight that reports `create_path_fixes`.
  Verified: preflight `create_path_fixes ON`, backlog 4096, cgroup pool 1408 ready, 10/10 neighbour entries PERMANENT,
  runner `0fd55bab4ad6`, api `bc21226c839b`.
- The first launch (`…_063230-ABORTED`) produced no data: the `systemd-run` unit's `LimitNOFILE` refused `ulimit -n 1048576`.
  It was rerun with `-p LimitNOFILE=1048576`.

### Startup (fixes ON)
| | 1k idle (recheck) | 2k idle | 2k agent |
|---|---|---|---|
| create p50 (s) | 0.72 / 0.70 / 0.68 | **1.42 / 1.57 / 1.48** | 11.98 / 12.07 |
| create p95 (s) | 1.10 / 1.12 / 1.12 | **3.02 / 3.02 / 2.97** | 24.50 / 24.43 |
| all ready (s) | 1.70 / 1.68 / 1.23 | **4.44** / 15.42¹ / **4.38** | **27.24 / 29.47** |
| failed | 0 | 0 | 0 |
| peak host memory | 61 GiB | 109–112 GiB | 322–323 GiB |
¹ One sandbox's `echo ready` took 13.3 s, and another waited 5.6 s for its toolbox after resume (same 5 s tail as §6). It was the
only toolbox wait over 1 s in 6,000 idle 2k creates and 0 in 3,000 1k creates.

Against HQ Vera and the 9575F at 2k (fixes ON, `BASELINE-EPYC9575-FIXES-20261014.md` §4):
| 2k | Graviton5 | 9575F | Vera |
|---|---|---|---|
| idle create p50 / p95 | **1.5 / 3.0 s** | 2.4 / 3.6 s | 2.9 / 6.5 s |
| idle all ready | **4.4 s** (one run 15.4) | 4.6 s (one run 17.7) | 6.6–7.2 s (one run lost) |
| agent create p50 | **12.0 s** | 19.7 s | 28.5 s |
| agent all ready | **27–29 s** | 58–71 s | 50–55 s |
| failures | 0 | 0 | 2 + 1 lost run |

### Throughput ladder, fixes ON (levels 1,056–2,000; exec timeout 1,800 s)
| c | jobs/s | job p50 | job p99 | failures | (fixes OFF, 2026-10-14) |
|---|---|---|---|---|---|
| 1,056 | 22.49 | 43.0 s | 107 s | 0 | 22.79 |
| 1,408 | 22.86 | 57.7 s | 123 s | 0 | 22.86 |
| 1,760 | 22.94 | 73.8 s | 147 s | 0 | 22.90 |
| 2,000 | **23.38** | 83.5 s | 154 s | 0 | 22.96 |
Peak host memory 504 of 754 GiB. 0 socket timeouts, 0 self-cordons. Vera at 2,000: 26.11 jobs/s (job p50 34 s, 1 failure);
9575F 8.03 (p50 239 s, 1 failure).

**Notes.**
- 571 `create-admission gate: live vms at cap` at 07:18, at the 1,760 → 2,000 transition: level 1,760's deletes overlapped
  level 2,000's creates past `RLP_MAX_LIVE_VMS=3000`. It inflates create_wall (42 s) but not the exec-phase jobs/s. Vera's 2k
  ladder ran level 2,000 alone.
- One create was redelivered after `snapshot/load` failed with `Open tap device failed: Resource busy` (a recycled netns
  whose tap was still held), during 2k agent rep 2. The retry succeeded, so no client failure.

Host state after the run: fixes ON (as on HQ Vera / 9575F), unpinned, no sandboxes, apt timers stopped until reboot.

## 8. Memory-bandwidth ladder (power-mem kit), 2026-10-15 13:09–13:25 UTC

Kit: `data/power-mem-20261015/` (checksums OK), run as `HOSTP=graviton5 mem-ladder.sh` from `~/power-mem`, detached with
`systemd-run -p LimitNOFILE=1048576`. Power was skipped because AWS exposes none. Result dir:
**`/mnt/data/bench/mem-graviton5-20261015_130901`**, copied to `mem-ladder-20261015.tgz`.
Preconditions verified: no other operator (the only activity since §7 was a read-only `ipmitool` probe at 09:48–09:50),
0 firecrackers, `create_path_fixes ON`, rlp.slice 0-191, kernel 6.17.0-1017-aws 4 KiB, apt timers inactive, preflight PASS
before every rep.

**Deviation: image `buildpack-deps:bookworm` instead of `gcc:14`** (`MEMFLEET_IMAGE`). On this bench build (`f0611fa13`
guest init), `gcc:14` sandboxes kernel-panic at boot. The image's ENV `GPG_KEYS`/`GCC_MIRRORS` values contain spaces, the old
init writes `export GPG_KEYS=<k1> <k2> …` unquoted into `/.rlp-launch`, the shell aborts, and PID 1 exits ("Attempted to kill
init"). `main` already quotes it (`lb_quote` in `guest/init`). All hosts in the comparison run the old init, so `gcc:14` will
fail on every one of them. `buildpack-deps:bookworm` is the base that `gcc:14` is built on, and its only ENV is PATH; it has gcc 12.2.
Measured on the host directly, one core: gcc 14.4 → 56.9 / 56.9 GB/s, gcc 12.2 → 56.8 / 56.6 GB/s, a difference under 0.5%.
**Use the same image on every host.**

**Kit measurement caveat:** `start_skew_s` and `overlap_s` in the summary come from memtest's guest-clock timestamps. Snapshot
clones keep the template's clock (daytona/rlp#767): the guest clock lagged the host by 507 s at the first level and 964 s at the
last. So those fields measure the spread in resume times, not start skew. Host-side recheck (`scripts/memskew.py`, from
memfleet's host timestamps `t_exec_send`/`t_exec_done`): exec send spread ≤ 6 ms at every level, and every memtest overlapped
for its whole 30 s (min done − max send ≥ 30.2 s; memtest duration 30.00–30.10 s). The aggregates are valid.

| sandboxes | aggregate GB/s (r1 / r2) | per-sandbox p50 / min GB/s | host send spread | failures |
|---|---|---|---|---|
| 1 | 57.9 / 57.0 | 57.9 / 57.0 | 0 | 0 |
| 8 | 365.1 / 337.7 | 45.6–45.8 / 35.0–45.0 | 0 ms | 0 |
| 32 | 594.2 / 593.9 | 17.9–18.6 / 16.2–18.2 | 1 ms | 0 |
| 64 | **603.9 / 603.9** | 8.8 / 7.3–7.8 | 2 ms | 0 |
| 128 | 571.6 / 572.0 | 4.3–4.4 / 3.3–3.6 | 4 ms | 0 |
| 176 | 582.4 / 582.2 | 3.3 / 2.7 | 6 ms | 0 |
(256 and 352 skipped: above 192 CPUs.)

- **Single sandbox (one vCPU): ~57.5 GB/s.** That is the same as a bare host process pinned to one core (56.9), so the microVM
  costs nothing measurable for streaming bandwidth.
- **Plateau ≈ 600 GB/s, reached by 32 sandboxes** (594 at 32, 604 at 64). It eases to 572–582 GB/s at 128–176, about −4%,
  probably from contention. Per-sandbox bandwidth past saturation is simply the plateau divided by the count.
- 0 failures in 818 measured sandboxes (2 reps × 409). STREAM convention: write-allocate traffic not counted.

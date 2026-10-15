# HQ Vera bench cell — findings log

Cell: daytona f0611fa13 + EROFS 4k (#1060) + RLP_FC_SOCK_WAIT_MS knob (#3212) + RLP_FC_SMT (inactive);
daemon rlp-rs-0.4.1; stock Firecracker v1.16.1; kernel 6.17.0-1032-nvidia-64k; preempt=none; 600 W cap.
Workload: create-ready, 0.025 CPU / 64 MiB / 1 GiB disk / 1 vCPU, probe `echo ready`, client pool 1024 (4096 at 2k).

## Headline (2026-10-14, supersedes earlier readings)

**The benchmark image's entrypoint dominates "startup".** `dtgraviet/vera-agent-benchmark:v3` boots into
`python -m workload.agent --n 30 --seed 42`; the runner releases the entrypoint gate on every sandbox, so each one runs a
CPU-bound job as soon as it is running (1.0 core for ~3.1 s on a quiet host). During a 1k burst the guests hold the socket
at 100% for 30+ s (`rlp.slice/vms` 171–183 cores mean). (cpu-burst-*, entry-probe)

Same 1k burst, 16 client processes, interleaved:

| host | image | placement | all-ready s | p95 s | guest CPU (vms cgroup) mean / peak |
|---|---|---|---|---|---|
| HQ Vera | agent | pinned socket 0 | 10.2, 10.4 | 9.6, 10.0 | 171 / 176 |
| HQ Vera | agent | unpinned | 22.0, 22.5 | 21.9, 22.3 | 183 / 350 |
| HQ Vera | alpine:3.20 | pinned socket 0 | 4.0, (11.6)* | 3.9, 3.8 | 2 / 22–27 |
| HQ Vera | alpine:3.20 | unpinned | (11.1)*, 4.2 | 4.0, 4.2 | 3 / 34–38 |
| EPYC 9575F | agent | 1 socket | 27.5, 24.5, 31.5 | 19.7, 21.9, 19.8 | 112 / 125 |
| EPYC 9575F | alpine:3.20 | 1 socket | 3.96, 3.99, 3.99 | 3.89, 3.92, 3.92 | 2 / 29–33 |

\* one `bad gateway: sandbox … not available` failure holds all-ready open (see #3229).

- **Platform startup path: ~4 s for 1,000 sandboxes on both HQ Vera and the 9575F**, placement-insensitive, ≤ 40 cores.
  The Vera "startup advantage" with the agent image is CPU throughput on the entrypoint workload.
- Identical ~4 s on two very different hosts suggests a shared bound outside host CPU (client, API, NATS dispatch).
  Not yet identified.
- The earlier "NUMA locality is the startup lever (2.3×)" reading was wrong: pinning only matters while guests run CPU
  work. Correction posted on daytona/rlp#391.

## Throughput (dense ladder, published recipe: n=45, -E 8, hold-then-exec, cpu 0.025/max 1) (tput-ab-20261014_125637)

| HQ Vera | c=176 | c=352 | c=704 |
|---|---|---|---|
| unpinned (both sockets) | 15.19/s | **26.57/s** | 25.89/s |
| pinned socket 0 | 14.03/s | 13.11/s | 12.96/s |

Published Vera 13.3 jobs/s was one socket. Whole HQ Vera ≈ 2× that. 0 failures.

## Burst bottleneck probes (pinned, agent image unless noted)
- `RLP_VM_MAXACK` (create-consumer MaxAckPending, default 256 vs pool 512): raising it to 1024 lets 512 clones run at once
  but all-ready is unchanged pinned (9.9/10.7 vs 10.2/10.6 s) and unpinned (19.9/28.6 vs 21.6/22.4 s). Not the lever.
  (burst-ab-20261014_113702)
- KVM `halt_poll_ns` 500000 → 0: no change (10.4 s, socket still 100%). (cpu-burst-20261014_123127)
- Per-clone phases at 512 in flight: clone_ms p50 2.1 s, of which named phases (scratch cp, FC start, load, toolbox
  wait) are ~0.5 s; the rest is un-instrumented (trackBoot/registerInstance under m.mu, setupCgroup, deliveries).
  Under the entrypoint storm this is CPU starvation. (perf-burst-20261014_121207)
- Host `perf` cannot attribute the guest-mode samples (~95% of the socket) without KVM-specific options; use cgroup
  `cpu.stat` accounting instead.

## #3213 (2-vCPU snapshot clones) (mig-ab-20261014_100816)
| arm | RLP_MIGRATABLE | oops / clones |
|---|---|---|
| M1 | 1 | 46 / 497 (9.3%) |
| M0 | 0 | 33 / 496 (6.7%) |
| M1b | 1 | 23 / 498 (4.6%) |
No effect (pooled 6.9% vs 6.7%). Same template for all arms. Signature always `__rb_erase_color` ← `vma_interval_tree_remove`
← `exit_mmap` ← `do_exit` on vCPU 1, `Comm: tokio-rt-worker`, guest uptime 1.154 s (= snapshot instant). Hypothesis:
template snapshot taken while a warmup child is mid-exit (template.go pauses right after WarmToolboxInNetns).
Posted on #3213 with next experiments (settle before pause; per-template variance; 4 KiB host kernel).

## Ruled out (measured on this host)
| factor | result | data |
|---|---|---|
| toolbox proxy capacity | 1 proxy vs LB->1 vs LB->4 identical; ~1 CPU-s per 1k burst | proxy-scale-20261014_081213 |
| event auditing (RLP_EVENT_AUDIT) | no effect | audit-ab-20261014_064901 |
| API restart / accumulated rows | no effect | audit-ab, pin-ab |
| second socket for the control plane | not needed | cp-split-20261014_074122 |
| NVIDIA SMT Firecracker fork (1 vCPU guests) | no effect (Daniel's drop-ins were active) | fc-arms-20261014_013902 |
| FC API-socket wait 3 s vs 30 s | removes spawn timeouts + self-cordons, medians unchanged | fcsock-ab-vera-20261014_003117 (#3212) |
| RLP_VM_MAXACK 256 vs 1024 | no effect on all-ready | burst-ab-20261014_113702 |
| KVM halt_poll_ns 0 | no effect | cpu-burst-20261014_123127 |
| RLP_MIGRATABLE for #3213 | no effect | mig-ab-20261014_100816 |

## Client
- "Accept" (`post_s`) from one Python process is client queueing: 1→16 processes, accept p50 2.9–5.8 s → 0.23–0.50 s,
  all-ready unchanged. (client-split-20261014_091923, pinned)
- `mpfleet.py` bug fixed: `--procs` > `--count` hung the barrier (empty shard).

## Open
- What bounds the idle-image 1k burst at ~4 s on both hosts.
- #3213 settle-before-pause experiment.
- 9755 idle-image startup (host key changed; not reachable).
- Readiness gate is a bare TCP accept (#3229).

## Create path, step by step (2026-10-14 afternoon) — full report: CREATE-PATH-STEPS.md
- Unloaded: POST -> running 65 ms p50 (API ~5 ms, runner ~59 ms of which Firecracker spawn 39 ms), first exec 21 ms.
- 23% of unloaded creates stall ~580 ms at the toolbox probe: guest answers queued SYNs late after resume (pcap).
- 1k idle-image burst (POST -> running p50 2.09 s): queue for the 256 in-flight slots 1.2 s; per-clone 16 MiB init-disk
  copy + fsync 313 ms (NVMe at 6 GB/s, 97% util); cgroup mkdir queue 157 ms; API under 1k POSTs ~190 ms.
- Scratch on tmpfs: p50 1.49 s (-28%); the cgroup step becomes the bottleneck (cgroup creation floor 0.92 s per 1k).
- Ruled out: fork serialization, cgroup2 favordynmods.
- Leak: 1,460 orphaned init-disk copies (23 GB) in /mnt/data/rlp/scratch from the 01:34 UTC window.
- 580 ms stall root cause (#3265): host's first ARP lost during restore (FAILED neigh in 53/60 pool netns), daemon
  resume GARP never fires on arm64 (monotonic clock restored), 1 s keepalive phase = 558 ms. Permanent neighbour
  entry: 27% -> 0% -> 25%. Guest wall clock 2 h 52 min behind (comment on #767).
- API under 1k burst (#3269): DB pool not the limit (<=16 of 64 active; 256 = no change); accept backlog 128 ->
  ~550 listen overflows per burst, ~1 s retransmits; warm connections: API share ~110 ms.
- Issues: #3260 (init-disk fsync), #3261 (cgroup creation), #3265 (ARP stall), #3269 (API backlog).
- PATCHED + re-measured (2026-10-14 late): all four fixes behind env flags on the same binary (control = flags off).
  1k idle-image burst POST->running p50 1927 -> 1054 ms (-45%), p90 3035 -> 1748 ms; unloaded p99 658 -> 73 ms,
  toolbox stalls 4/60 -> 0/60. Per-fix: initdisk nofsync 9b 300->9 ms; cgroup pool (warm from runner start) 9f
  201->24 ms; backlog 4096 overflows 424-687 -> 0 but end-to-end slightly worse alone. Remaining: queue for a
  runner slot 421 ms, FC spawn 200 ms. Patches: patches/*.diff. Cell left on patched binaries, flags off.
- Harness benchmarks with fixes (published method, fixes off vs on, unpinned): idle 1k startup create p50
  2.07-2.39 -> 1.51-1.62 s, p95 3.30-3.76 -> 2.54-2.61 s; agent-image startup unchanged (CPU-bound);
  throughput unchanged (26.7 jobs/s at 352). Tails held by wedged guests (1-vCPU oopses ~1.3 s uptime, #3213
  family), 10 failures off vs 7 on. Harness read timeout knob added (SDK read=None hung a ladder forever).
- 1-vCPU post-resume oops reproduced with traces (#3213 comment): 3/1497 clones (0.2%), all 10-30 ms after resume
  in the entrypoint process; 2x __handle_mm_fault with x0=dead000000000122 (LIST_POISON2), 1x touch_atime/erofs
  read with a garbage file pointer. 0/2000 on an older template (per-template variance suggestive, not proven).
- Harness read-timeout knob committed to the harness PR (danielgraviet/arm64-benchmark-1#1, 4 commits).
- 2026-10-14 ~21:00 UTC: fixes left ON at HQ Vera (drop-ins 20-create-path-fixes.conf); preflight now reports
  create_path_fixes. Reference results: BASELINE-VERA-FIXES-20261014.md/.json (generated from raw data).
- EPYC 9575F on the same bench build (f0611fa13 + patches), fixes OFF vs ON: idle 1k create p50 2.47-2.58 ->
  0.98-1.10 s (-57%), p95 3.36-3.91 -> 1.57-1.60 s; agent p50 7.8 -> 6.6-8.3 s; throughput 8.0 jobs/s unchanged.
  Vera vs 9575F with fixes ON: startup p50 1.57 vs 1.06 s (9575F faster), throughput 26.7 vs 8.0 jobs/s (Vera
  3.3x). Level-704 ladders need RLP_HTTP_READ_TIMEOUT_S=600 on the 9575F (p50 83 s). Both hosts left fixes ON.
  -> BASELINE-EPYC9575-FIXES-20261014.md/.json
- 2,000 sandboxes, fixes ON, both hosts: idle startup p50 9575F 2.34-2.46 s vs Vera 2.79-3.00 s (p95 3.6 vs 6.5);
  agent startup p50 19.7 vs 28 s but all-ready 58-71 vs 50-55 s; level-2000 ladder 8.03 vs 26.11 jobs/s, 1 failure
  each (proxy dial i/o timeout, both archs); ~180 MiB per sandbox, peak mem 35% / 32%. 9575F max job 553 s at 2000
  (harness default exec timeout 600 s nearly hit). One Vera startup run lost to a wedged sandbox.
- 2026-10-15 power + memory kit (power-mem-20261015/RESULTS.md): jobs/s per kW processor Vera 23.6-23.7 (AP) vs
  9575F 21.0-21.2 (pkg); J/job 42.1-42.3 vs 47.2-47.7; Vera AMD-like scope (CPU rail out + SOC) ~29-32 jobs/s/kW.
  9575F wall 11.2-11.5 jobs/s/kW (Vera has no wall sensor). Idle: Vera AP 225 W / Total 282 W; 9575F pkg 54 W / wall 133 W.
  Both at power limit at plateau (Vera 600 W/socket cap; 9575F ~400 W pkg); clock 44->packed Vera -0.6%, 9575F -15%.
  Memory triad plateau Vera ~2.1 TB/s vs 9575F ~0.30 TB/s; single sandbox 72 vs 46 GB/s.
  Blockers hit: gcc:14 kills guests on the pre-#1554 guest init (fixed on main 98a1be351); 9575F lacked mkfs.erofs.

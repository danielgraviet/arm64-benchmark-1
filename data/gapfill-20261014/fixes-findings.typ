#set document(title: "Fixes and findings behind the improved benchmark results", date: datetime(year: 2026, month: 10, day: 14))
#set page(paper: "a4", flipped: false, margin: (x: 1.5cm, y: 1.6cm), numbering: "1 / 1",
  header: context { if counter(page).get().first() > 1 [#set text(8pt, fill: gray); Fixes and findings behind the improved benchmark results #h(1fr) Daytona rl-platform · 2026-10-14] })
#set text(font: ("Libertinus Serif", "New Computer Modern"), size: 9.6pt)
#set par(justify: false, leading: 0.58em)
#set heading(numbering: "1.")
#show heading.where(level: 1): it => block(above: 1.2em, below: 0.6em, text(12.5pt, weight: "bold", it))
#show heading.where(level: 2): it => block(above: 0.9em, below: 0.45em, text(10.5pt, weight: "bold", it))
#show table: set text(8.3pt)
#set table(stroke: 0.4pt + rgb("#bbbbbb"), inset: (x: 4.5pt, y: 3.2pt))
#show table.cell.where(y: 0): set text(weight: "bold")
#show table.cell.where(y: 0): set table.cell(fill: rgb("#eef1f5"))
#let good(x) = text(weight: "bold", fill: rgb("#1a6b2f"), x)
#let note(body) = block(fill: rgb("#f3f5f8"), inset: 7pt, radius: 3pt, width: 100%, text(8.8pt, body))

#align(center)[
  #text(17pt, weight: "bold")[Fixes and findings behind the improved benchmark results]
  #v(-0.4em)
  #text(11pt)[Daytona sandbox benchmarks: HQ Vera, Graviton5, Turin, EPYC 9575F / 9755 and earlier cells]
  #v(-0.2em)
  #text(8.5pt, fill: gray)[Compiled 2026-10-14 from the three working sessions (Vera / project-wide since 1 Sep, Graviton5, Turin), read up to about 21:00 UTC. The Turin density ceiling and the Vera / 9575F reruns with the fixes on were still running.]
]

#note[
*How to read this.* Section 1 lists platform code changes, section 2 host and configuration fixes, section 3 client and
harness fixes. Section 4 lists findings that changed how earlier numbers must be read — some "improvements" were really
corrections of a contaminated measurement. Section 5 is what was tested and made no difference; section 6 is still open.
Numbers are before → after on the host named.
]

= Platform code fixes

== Create path: four fixes, each behind a flag (HQ Vera, 14 Oct)

#table(columns: (1.1fr, 1.7fr, 1.9fr),
  [Fix], [What changed], [Effect],
  [*\#3260* `RLP_INITDISK_MODE=nofsync`], [No 16 MiB init-disk copy with fsync per sandbox], [That step 300–322 ms → #good[9 ms]],
  [*\#3261* `RLP_CGROUP_POOL=1400`], [cgroups pre-created when the runner starts], [188–201 ms → #good[24 ms]; under a burst 454 → 154 ms],
  [*\#3265* `RLP_NEIGH_PERMANENT=1`], [Permanent neighbour entry; removes a ~580 ms stall after a sandbox resumes], [Stalls 4/60 → 0; single-create p99 657 → 73–81 ms],
  [*\#3269* `RLP_API_LISTEN_BACKLOG=4096`], [API listen queue 128 → 4096], [Dropped connections 424–687 → 0; connect p90 1.06 s → 51 ms],
)

#table(columns: (2.2fr, 1fr, 1fr, 0.8fr),
  [All four on — measurement], [Fixes off], [Fixes on], [Change],
  [Vera, own client, idle image, 1k: request → running p50], [1.93 s], good[1.05 s], [−45 %],
  [Vera, own client: all 1,000 running], [2.95–3.88 s], [2.33–2.37 s], [],
  [Vera, single create p50 / worst], [67 / 658 ms], [64 / 73 ms], [],
  [Vera, Daniel's harness, idle image, 1k: p50], [2.07–2.39 s], good[1.51–1.62 s], [−30 %],
  [Vera, Daniel's harness: p95], [3.30–3.76 s], [2.54–2.61 s], [−27 %],
  [Graviton5, idle image, 1k: typical sandbox], [≈ 2.2 s], good[0.85 s], [],
  [Graviton5, idle image: p95], [≈ 3.4 s], [1.55 s], [],
  [Agent image startup, both hosts], [10–14 s], [unchanged], [none],
  [Throughput (Vera 352 / Graviton5 704)], [26.7 / 22.8 jobs/s], [26.7 / 22.9 jobs/s], [none],
)
#text(8.5pt)[Remaining burst limits after the fixes: waiting for one of the runner's 256 in-flight slots (421 ms) and Firecracker
start (200 ms). Open: on Graviton5, 5 of 3,000 fixes-on sandboxes waited 5.1–5.7 s for their toolbox (one run 7.6 s).
These fixes live only in the benchmark build; none is merged.]

== Other platform fixes

#table(columns: (1.5fr, 2.4fr, 0.9fr),
  [Fix], [Effect], [Status],
  [*Sudo storm* (\#1754, `1b2da010a`; bounded privileged-exec pools)], [BM1/BM2 at 1,800 sandboxes: 1,720 of 1,880 failed → #good[0 of 3,600]; p50 260 → 20 s. At 1,408: p50 13.8 → 12.8 s], [Upstream],
  [*\#3212* Firecracker socket wait 3 s → 30 s (`RLP_FC_SOCK_WAIT_MS`)], [Vera: 177–304 timeouts and 6–10 runner self-cordons per 1k → 0. 9575F: 15–48 → 0. Medians unchanged; removes 50–80 s stragglers], [Knob in bench build; issue filed],
  [*\#1060* EROFS 4 KiB blocks on 64 KiB-page hosts], [Vera creates: always failing → working], [Bench build; PR open],
  [*\#1066* balloon off on 64 KiB-page hosts], [Guest memory corruption: 14/64 failed → 0/544], [Applied on all cells],
  [*\#768* `RLP_CLOCK_REALTIME=0` (nested KVM)], [Snapshot clones restored on DigitalOcean: 10 s → under 1 s], [PR],
  [*Create-queue cap* `CREATE_MAX_QUEUE_SECS_CAP`], [Hard-coded to 60 s; the env setting is clamped. It stopped Turin's 5,000 level (962 of 1,059 failures)], [Patched locally on Turin],
  [*Overload gate* `RLP_MAX_QUEUED_CREATES` (default 8,000)], [Turin's next stop at 8,000 live; raised to 40,000 → past 8,000 with 0 failures], [Turin, running],
)

= Host and configuration fixes

#table(columns: (1.6fr, 0.8fr, 2.3fr),
  [Fix], [Host(s)], [Effect],
  [*Stopped `rlp-cpu-weight-floor.sh`* (busy loop, 10 days)], [9575F], [1k median 18.6 → 9.7 s; all-ready ~36 → ~20 s; 500 sandboxes 20.4 → 7.2 s. It ran during the published 2 Oct runs],
  [*Hostname added to `/etc/hosts`*], [RedSwitches, 9575F, all new cells], [Every `sudo` waited on DNS: 113 s (or >25 s) → 0.2 s. The runner could not start without it],
  [*ARP table* `gc_thresh3` 1,024 → 65,536 (v4 + v6)], [BM1/BM2, OCI, atl1, all cells], [704 sandboxes: 1,324 failures → 0; 1,056: host unreachable → 98 % succeeded; peak 55.9 → 62.7 jobs/s],
  [*Per-sandbox memory burst cap* 32 GiB → 512 MiB], [BM1/BM2], [2,112 sandboxes: 14.4 → #good[137.6 jobs/s]; 1,408: 12.3 → 83.2; OOM kills 406 → 0],
  [*Client open-files limit* 1,024 → 1M, plus HTTP connection pool], [Vultr BM], [1,056 sandboxes: 484 failures → 0],
  [*Toolbox wait* 60 → 300 s], [BM pair], [1,408: 1,210 failures → 1 (later credited mostly to the sudo fix)],
  [*Teardown concurrency* 128 → 256], [BM pair], [Teardown no longer trips the live-VM cap between levels],
  [*E2B huge pages released* (400,000 → 0)], [HQ Vera], [Usable memory ~2 GB → 1.44 TB; a 2k run was impossible before],
  [*udev iscsi rule shadowed; libvirtd and fwupd stopped*], [OCI, HQ Vera, Turin, Graviton5], [No background work on every sandbox interface change (OCI alone: 574 → 461 failures, near noise)],
  [*Postgres and NATS off the boot disk* (\#707)], [Ashburn, OCI], [fsync 1.3 ms → 0.03 ms (47×); 1,079 → 14 µs (75×)],
  [*12-disk RAID10 removed* (60 h resync)], [Turin], [Matches Vera's single-NVMe layout; no resync competing with runs],
  [*Stale firewall tables removed*], [HQ Vera], [Guest replies had been dropped],
  [*Policy-routing rule* (priority 95)], [atl1], [Toolbox unreachable → 0 failures to 704],
  [*Capacity for the ceiling test*: netns pool 6,200, max live 8,000, /18 subnet], [Turin], [A /20 subnet caps a host near 4,094 sandboxes],
  [*Lower API minimums / memory-per-CPU floor*], [Vera, RedSwitches], [Small shapes had been silently rounded up],
  [*Runner prerequisites (\#724), EVENTS stream (\#708), wedged NATS consumer, pre-warmed template*], [early cells], [Failing creates fixed; a cold template caused a second 60 s delivery],
  [*Leaked sandboxes, taps, `/run/fc` and scratch cleaned*], [BM pair, RedSwitches], [Next run clean (70.3 jobs/s at 704)],
  [*Pin Vera to one socket for the agent burst*], [HQ Vera], [22 → 10 s — only with CPU-heavy guests; pinning hurts Turin and Graviton5],
)

= Client and harness fixes

#table(columns: (1.6fr, 3fr),
  [Fix], [Effect],
  [*`mpfleet.py`, 16 client processes*], [“Accept” 2.9–5.8 s → 0.12–0.5 s. Turin 1k: 10.2 → 7.9 s. A single Python process was queueing requests],
  [*SDK `int(memory)*1024` / `int(disk)*1024` bug*], [Fractional sizes became 0 → HTTP 400, or a silent 1 GiB default. Every Turin ceiling run reserved 1 GiB scratch and stopped at exactly 6,742; with 64 MiB it went past 8,000],
  [*Teardown in `finally` + SIGTERM handler*], [Interrupted runs no longer leak their fleet (the cause of the lockouts)],
  [*`RLP_HTTP_READ_TIMEOUT_S=120`*], [One wedged sandbox no longer turns a level into 1.47 jobs/s or a 26-minute stall],
  [*`--rlp-cpu-max 1` required*], [Without it the harness sends `mode=dedicated`, which fails with HTTP 400],
  [*`.env` pointed at `127.0.0.1`* (EPYC 9755)], [It pointed at the public API: 100 % failure → 0 at 880 / 1,056],
  [*HTTP pool 100 → 600* (Daniel)], [Short-job rate on Vera ~82 → ~129],
  [*`bench-preflight`*], [Refuses to run with the busy loop, leftover sandboxes, a filling netns pool, huge pages, a low ARP limit or the balloon on],
  [*Warm-up after snapshots are deleted*], [Graviton5's “2.3× memory on 64 KiB pages” was full boots; the real figure is +8 %],
)

= Findings that changed how results read

- *The agent image measures its own workload, not startup.* Each sandbox burns 3–4 CPU-seconds at boot. With an idle
  image 1,000 sandboxes start in ≈ 4 s on Vera and the 9575F and 3.8 s on Graviton5, not 10–30 s. Daytona's own CPU cost is
  ≈ 28 ms per sandbox.
- *“Control plane accepts the request” was the single-process client*, not the control plane.
- *Pinning helps only Vera, and only with CPU-heavy guests.* Vera's cross-socket memory costs 3.08× vs 1.25× on
  Graviton5. Pinning halves throughput everywhere. The “NUMA is the startup lever” claim was withdrawn on \#391.
- *Published-data corrections.* The 9575F 2k mean keeps a 151 s outlier and was taken with the busy loop on (clean
  76–91 s). The 9755's 88.4 s drops a run (all four average 91.1 s). Vera's 2k throughput point had 53–627 failures.
  September and October startup figures come from different hosts and builds.
- *A second operator invalidated runs.* Daniel's agent worked on HQ Vera overnight; “API restart makes it fast” was
  retracted. Rule: one operator per box.
- *Measurement traps.* A 0.5 s poll interval sets small-burst numbers; `checksum_ok` is false on any failure;
  capacity-gate failures are not platform failures; middle throughput levels vary ±30 %, only the plateau is stable.
- *Throughput = cores × per-core speed when packed.* Platform overhead is 0.5–0.6 % of each job. Clock under full load:
  9575F −24 %, Vera −6 %, Graviton5 −3 %. Memory bandwidth is not a factor.
- *64 KiB host pages:* no speed gain on Graviton5 (≤ 1.5 %); ≈ 8 % more host memory per sandbox, enough to OOM one NUMA
  node at 1,408 sandboxes.

= Tested with no effect

#grid(columns: (1fr, 1fr, 1fr), gutter: 6pt,
  [- Event auditing off
   - API restarts
   - Quiet-progress runner
   - `cpuidle.off` + `init_on_alloc=0`
   - KVM `halt_poll_ns`],
  [- `RLP_VM_MAXACK`
   - `VM_CONCURRENCY` 192 vs 512
   - API DB pool 64 → 256
   - Proxy scaling (1 vs 4)
   - Dedicated control-plane cores],
  [- NVIDIA SMT Firecracker fork
   - `RLP_MIGRATABLE=0` (\#3213)
   - Client pool / polling / disk size
   - Memory bandwidth, kernel version
   - cgroup `favordynmods`, XFS prealloc
   - Create-queue env (clamped to 60 s)],
)

= Still open

- *\#3213* — 2-vCPU snapshot clones crash ≈ 7 % on Vera; 1-vCPU ≈ 0.02 %.
- *\#3229* — a sandbox counts as running as soon as its toolbox port accepts, so a hung guest looks healthy.
- *Graviton5 with fixes on* — rare 5 s toolbox waits (5 in 3,000).
- *Turin idle-image startup* — ≈ 8 s per 1,000 vs ≈ 4 s on Vera and the 9575F; unexplained.
- *Pending runs* — Vera and 9575F reruns with the fixes on; Turin density ceiling above 8,000.
- *Never tested* — `preempt=none` vs `full`; 4 KiB vs 64 KiB host pages on Vera itself.

#set document(title: "Vera vs Turin vs Graviton5: sandbox benchmark status", date: datetime(year: 2026, month: 10, day: 14))
#set page(paper: "a4", margin: (x: 1.6cm, y: 1.7cm), numbering: "1 / 1",
  header: context { if counter(page).get().first() > 1 [#set text(8pt, fill: gray); Vera vs Turin vs Graviton5 — status 2026-10-14 15:05 UTC #h(1fr) Daytona rl-platform benchmarks] })
#set text(font: ("Libertinus Serif", "New Computer Modern"), size: 10pt)
#set par(justify: false, leading: 0.6em)
#set heading(numbering: "1.")
#show heading.where(level: 1): it => block(above: 1.3em, below: 0.7em, text(13pt, weight: "bold", it))
#show heading.where(level: 2): it => block(above: 1.0em, below: 0.5em, text(11pt, weight: "bold", it))
#show table: set text(8.6pt)
#set table(stroke: 0.4pt + rgb("#bbbbbb"), inset: (x: 5pt, y: 3.5pt))
#show table.cell.where(y: 0): set text(weight: "bold")
#let hi(x) = text(weight: "bold", fill: rgb("#1a6b2f"), x)
#let lo(x) = text(fill: rgb("#a33a1a"), x)
#let na = text(fill: gray, [—])
#let note(body) = block(fill: rgb("#f3f5f8"), inset: 8pt, radius: 3pt, width: 100%, text(9pt, body))

#align(center)[
  #text(18pt, weight: "bold")[Where does Vera shine?]
  #v(-0.4em)
  #text(12pt)[Daytona sandbox benchmarks on HQ Vera, AMD EPYC 9J45 (Turin) and AWS Graviton5]
  #v(-0.2em)
  #text(9pt, fill: gray)[Status report — data as of 2026-10-14 15:05 UTC. Two of the three hosts are still being measured.]
]

#note[
*Sources.* HQ Vera cell findings (`data/vera-hq-cell-20261014/FINDINGS.md`); phoenix-e6 (Turin) cell findings and
live run logs (`/mnt/data/bench/{pin-ab,burst2k,ladder}-20261014_*`); Graviton5 suite logs
(`/mnt/data/bench/suite-{4k,64k}-20261014_*`); Daniel's published dataset (`daniel-focus-here/public/`) for the
September Vera one-socket ladder and the EPYC 9575F / 9755 points. Every number below was measured with the same
Daytona build on all three new cells (runner `353a4060945c` on arm64; the same commit built for x86\_64 on Turin),
Firecracker v1.16.1, daemon `rlp-rs-0.4.1`, and the same harness and recipe.
]

= Summary

#table(columns: (auto, 1fr), stroke: none, inset: (x: 4pt, y: 3pt),
  [#hi[Vera leads]], [*Per-core compute.* One job takes *5.9 s* on Vera against 6.6–6.7 s on Graviton5 and the
    EPYC 9575F, and 7.1 s on the EPYC 9755, with almost no contention (c = 44). Packed, Vera delivers about
    *0.15 jobs/s per physical core* (using SMT), against 0.12 on Graviton5 (no SMT), 0.13 on the 9575F and
    0.09 on the 9755. The 5.9 s comes from the September one-socket data and still needs re-measuring on the current build.],
  [#hi[Vera leads]], [*Whole-box throughput so far.* *26.6 jobs/s* on HQ Vera (both sockets) against *22.9* on
    Graviton5 (+16 %). The published 13.3 jobs/s was one socket. Turin has not been measured yet.],
  [#lo[No lead]], [*Platform startup.* With an idle image, 1,000 sandboxes are ready in *≈ 4 s* on Vera and on the
    9575F. The earlier 2–3× startup lead came from the benchmark image running a CPU job in every sandbox.],
  [#lo[Turin leads]], [*Startup under load* (agent image, 16 client processes, whole box): Turin *7.9 s*,
    Graviton5 9.6–15.6 s, Vera 22 s unpinned / 10.2 s pinned to one socket. Spreading over both sockets hurts only
    Vera.],
  [#lo[Turin leads]], [*Density.* Turin held *4,000* idle sandboxes with 1.6 TB still free; its 5,000 level failed on
    the API's 60 s create-queue cap, not on the machine. Vera (1.5 TB) and Graviton5 (0.75 TB) are not measured.],
)

#v(0.3em)
*Bottom line so far:* Vera's advantage is *fast cores under CPU-bound sandbox work* — throughput and per-job
latency — not sandbox startup and not density. The Turin throughput ladder is the missing number that decides
whether the throughput lead holds against the strongest x86 box.

= Hosts and setup

#table(columns: (auto, 1fr, 1fr, 1fr),
  [], [HQ Vera], [Turin (OCI phoenix-e6)], [Graviton5 (AWS m9gd.metal-48xl)],
  [CPU], [NVIDIA Vera, 2 × 88 cores, SMT2 (352 thr)], [AMD EPYC 9J45, 2 × 96 cores, SMT2 (384 thr)], [Neoverse-V3, 1 socket, 192 cores, no SMT, 2 NUMA nodes],
  [Memory], [1,478 GiB], [2,267 GiB], [754 GiB],
  [Host kernel], [6.17 nvidia, *64 KiB pages*, `preempt=none`], [6.17 oracle, 4 KiB pages], [6.17 aws, 4 KiB (64 KiB A/B running), voluntary preempt],
  [Guest kernel], [6.12.34-rlp1 (arm64)], [6.8.12-rlp3 (x86\_64)], [6.12.34-rlp1 (arm64)],
  [Storage], [1 NVMe, ext4], [1 NVMe, ext4 (12-disk RAID10 removed)], [1 NVMe instance store, ext4],
  [“Half” (pinned) layout], [socket 0: 88 cores / 176 thr], [socket 0: 96 cores / 192 thr], [NUMA node 0: 96 cores],
  [Power telemetry], [ACPI AP power per socket], [RAPL package (no DRAM)], [none],
)

Runner settings are identical: 30 s Firecracker socket wait (#3212), 512 concurrent VM starts, 2,100 pre-built
network namespaces, balloon off, minimum sandbox 0.025 CPU / 64 MiB / 1 vCPU. Only `rlp.slice` is pinned in
“half” layouts; API, Postgres, NATS and the client float.

= Startup: time until all sandboxes are ready

Create-ready burst with probe `echo ready`; “all ready” = burst start → last sandbox ready and probed.
*Idle image* (`alpine:3.20`) measures the platform. The *agent image* (`vera-agent-benchmark:v3`) starts a CPU job
of ≈ 3 core-seconds in every sandbox, so it measures startup under load.

== 1,000 sandboxes (seconds)

#table(columns: (1.7fr, 1fr, 1fr, 1.2fr, 1fr),
  [Image · client · layout], [HQ Vera], [Turin], [Graviton5 4 KiB], [Graviton5 64 KiB],
  [*Idle* · 16 procs · whole box], [*4.0 – 4.2*#super[a]], [7.95, 7.96], na, na,
  [*Idle* · 16 procs · half], [*4.0*#super[a]], na, na, na,
  [Agent · 16 procs · whole box], [22.0, 22.5], [*7.90, 8.01, 7.97*], [9.82, 15.55, 9.56], [8.23, 13.71, 11.53],
  [Agent · 16 procs · half], [10.2, 10.4], [12.52, 11.89, 11.87], [15.69, 15.74, 15.83], [19.48, 19.48, 16.15],
  [Agent · 1 proc · whole box], [20 – 23], [10.61 – 11.21], [7.07 – 13.79], [7.20 – 11.98],
  [Agent · 1 proc · half], [8.4 – 10.6], [10.22 – 10.80], [14.84 – 18.62], [18.46 – 18.68],
)
#text(8.5pt)[#super[a] One rep per layout was held open to ≈ 11 s by a single sandbox whose commands hung after it
was marked running (#3229). EPYC 9575F, same idle test: 3.96 / 3.99 / 3.99 s. All Turin and Graviton5 reps landed
every sandbox with zero socket-wait timeouts and zero self-cordons.]

== 2,000 sandboxes (seconds)

#table(columns: (1.7fr, 1fr, 1fr, 1fr),
  [Image · client · layout], [HQ Vera], [Turin], [Graviton5],
  [Idle · 16 procs · whole box], na, [23.22], na,
  [Agent · 16 procs · whole box], [27.4 (published Sep, old client)], [*22.30, 21.94*], na,
  [Agent · 16 procs · half], na, [29.55, 30.97], na,
)

*Reading.* The platform's own startup is ≈ 4 s per 1,000 on Vera and the 9575F regardless of placement.
Turin is the outlier: its idle-image time (≈ 8 s) is the same as its agent-image time, so something other than
guest CPU bounds it there — unexplained so far. The single-process client queues requests in Python (accept p50
2.9–5.8 s vs 0.12–0.5 s with 16 processes), so 16-process numbers are the fair ones.

= Throughput: dense agent ladder (jobs/s)

Published recipe: agent workload, 45 jobs, 8 episodes per sandbox, hold-then-exec, 0.025 CPU (max 1),
64 MiB (max 4 GiB). *c* = sandboxes working at once. Zero failures unless noted.

#show table: set text(7.8pt)
#table(columns: (1.9fr, 0.55fr, 0.55fr, 0.6fr, 0.6fr, 0.6fr, 0.6fr, 0.65fr, 0.65fr, 0.65fr, 0.65fr, 0.65fr),
  [Host · layout], [44], [88], [176], [352], [528], [704], [880], [1056], [1408], [1760], [2000],
  [*HQ Vera · whole box*], na, na, [15.19], hi[26.57], na, [25.89], na, na, na, na, na,
  [HQ Vera · one socket], na, na, [14.03], [13.11], na, [12.96], na, na, na, na, na,
  [Vera · one socket (published Sep)], [6.0–6.6], [9.5–10.2], [11.8–13.7], [12.9–13.3], [12.9–13.4], [12.8–13.1], [12.8–13.0], [12.8–13.0], [12.8–12.9], [12.5–12.9#super[b]], [12.7–14.2#super[b]],
  [*Graviton5 4 KiB · whole*], [5.70], [11.94], [23.76], [22.63], [22.44], [22.73], [22.89], [22.79], [22.86], [22.90], [22.96],
  [Graviton5 4 KiB · node 0], [5.99], [11.94], [12.25], [12.02], na, [11.93], na, [11.83], [11.85], na, na,
  [Graviton5 64 KiB · whole#super[c]], [5.80], [11.91], [23.71], [23.62], [22.97], [23.15], na, na, na, na, na,
  [*Turin*], na, na, na, na, na, na, na, na, na, na, na,
  [EPYC 9575F (published)], [5.9], [7.4], [8.3], [8.2], [8.2], [8.1], [8.1], [8.0], [8.0], [8.1], [8.1],
  [EPYC 9755 (published)], [4.3–5.5], [8.3–8.4], [9.6–10.0], [10.7–11.5], [10.6–10.9], [10.7–11.3], [10.6–11.1], [10.7–11.3], [10.9–11.4#super[b]], [11.1–13.9#super[b]], [10.9–12.0#super[b]],
)
#show table: set text(8.6pt)
#text(8.5pt)[#super[b] Some runs at this level had failures (Vera 2000: 53–627; 9755 from 1408). #super[c] Running at
the time of writing; levels above 704 pending.]

== Derived: per-core speed

#table(columns: (1.5fr, 0.9fr, 0.9fr, 0.9fr, 0.9fr, 1.1fr),
  [Host (layout)], [Plateau jobs/s], [Cores / threads], [Jobs/s per core], [Jobs/s per thread], [Single job p50, c = 44],
  [*HQ Vera (whole box)*], [26.6], [176 / 352], hi[0.151], [0.075], [—],
  [Vera (one socket, published)], [13.0], [88 / 176], hi[0.148], [0.074], hi[5.9 s#super[d]],
  [Graviton5 4 KiB (whole box)], [22.9], [192 / 192], [0.119], hi[0.119], [6.65 s],
  [Graviton5 4 KiB (node 0)], [11.9], [96 / 96], [0.124], hi[0.124], [6.66 s],
  [Graviton5 64 KiB (whole box)], [≈ 23.2], [192 / 192], [0.121], hi[0.121], [6.63 s],
  [EPYC 9575F (published, 1 socket)], [8.1], [64 / 128], [0.127], [0.063], [6.72 s],
  [EPYC 9755 (published, 1 socket)], [≈ 11], [128 / 256], [0.086], [0.043], [7.12 s],
  [Turin], [not run], [192 / 384], [—], [—], [—],
)
#text(8.5pt)[#super[d] September data on an older build; the guest shape on that host may have allowed 2 vCPUs (each
job is still capped at 1 CPU by `--rlp-cpu-max 1`). The gap-fill ladder's c = 44 level re-measures it on the current
build.]

Vera's lead is per physical core: ≈ 27 % more jobs/s per core than Graviton5 and ≈ 19 % more than the 9575F,
and an ≈ 11 % faster single job. Vera gets there with SMT (2 threads per core); per hardware thread Graviton5 is
ahead (0.12 vs 0.075). Graviton5 has more cores, which narrows the whole-box gap to 16 %. Platform overhead is
0.5–0.6 % of each job, so these are effectively CPU numbers. Graviton5's 64 KiB host pages change nothing
measurable in throughput.

= Density: how many idle sandboxes fit

#table(columns: (1fr, 1fr, 1fr, 1fr, 2fr),
  [Host], [3,000], [4,000], [5,000], [Note],
  [Turin], [3000/3000 in 42.7 s], [4000/4000 in 81.9 s], [3941/5000], [962 of 1,059 failures were the API's 60 s create-queue cap (`CREATE_MAX_QUEUE_SECS_CAP`); 1,650 GiB free. Wave test running.],
  [HQ Vera], na, na, na, [Not measured (needs raised netns/live-VM caps and a /18 subnet).],
  [Graviton5], na, na, na, [Not measured.],
)

= Findings that change how earlier numbers read

- *The startup benchmark measured the image's own workload.* The agent image's entrypoint burns ≈ 3 core-seconds
  per sandbox; with an idle image Vera and the 9575F both land 1,000 in ≈ 4 s. Startup charts need redoing with an
  idle image or relabeling as “startup under load”.
- *“Control plane accepts the request” is mostly the Python client.* 1 → 16 processes: accept p50 2.9–5.8 s →
  0.23–0.50 s, all-ready unchanged.
- *NUMA placement only matters on Vera, and only for CPU-heavy guests.* Pinning Vera to one socket helps the agent
  burst (22 → 10 s); it halves throughput on Vera and Graviton5 (Turin not yet measured). The “NUMA is the startup lever” claim was withdrawn on #391.
- *The 9575F's published startup numbers were inflated* by a background busy loop; its published 2k mean keeps an
  outlier.
- *Reliability:* 3 s Firecracker socket wait causes spawn timeouts and self-cordons (#3212, fixed by the 30 s knob);
  2-vCPU snapshot clones oops on Vera ≈ 7 % (#3213); the runner marks a sandbox running on a bare TCP accept (#3229).
- *Ruled out on Vera:* proxy capacity, event auditing, API restarts, `RLP_VM_MAXACK`, KVM `halt_poll_ns`, the
  NVIDIA SMT Firecracker fork, memory bandwidth.

= What is missing, and the plan to fill it

Defined in `data/gapfill-20261014/PLAN.md` with `gapfill.sh`, `gapfill-sampler.py` and `capacity.sh`. Nothing has
run; each host waits until its current session is done (one operator per box).

#table(columns: (1.6fr, 1fr, 1fr, 1fr),
  [Measurement (one method on all hosts)], [HQ Vera], [Turin], [Graviton5],
  [Startup matrix: idle/agent × whole/half × 1k ×3, 2k ×2, 16 procs], [rerun; 2k missing], [half + agent 2k missing], [idle + 2k missing],
  [Throughput ladder, whole box, c = 44…2000], [only 176/352/704], lo[missing], [done],
  [Throughput ladder, half, c = 44…1408], [only 176/352/704], lo[missing], [done],
  [Power and clock during the ladder (jobs/s per watt)], lo[missing], lo[missing], [no telemetry],
  [Idle-density ceiling 3,000 → 6,000], lo[missing], [done (4,000+)], lo[missing],
)

Estimated time: ≈ 2.5 h each on Vera and Turin, ≈ 1 h on Graviton5, in parallel. The Graviton5 cell has already
rebooted into the 64 KiB kernel (14:19 UTC), so its gap-fill runs on 64 KiB pages unless it is switched back.

= Caveats

- Host page size differs (Vera 64 KiB; Turin and Graviton5 4 KiB, Graviton5 64 KiB A/B in progress) and so does
  preemption (Vera `preempt=none`; the AWS kernel cannot switch).
- Guest kernels differ by architecture (x86 6.8.12-rlp3, arm64 6.12.34-rlp1).
- Published September Vera and EPYC data used an older build and, on Vera, likely a forked Firecracker; they are
  used here only for the per-job and one-socket plateau points.
- Turin's single-NVMe layout deliberately differs from the OCI default RAID10, to match Vera.
- Power scopes will differ (Vera AP module vs AMD package without DRAM); Graviton5 exposes none.

#set document(title: "Vera vs EPYC 9575F vs Turin vs Graviton5 — comparison report v2", date: datetime(year: 2026, month: 10, day: 14))
#set page(paper: "a4", margin: (x: 1.5cm, y: 1.6cm), numbering: "1 / 1",
  header: context { if counter(page).get().first() > 1 [#set text(8pt, fill: gray); Comparison report v2 — data as of 2026-10-14 23:30 UTC #h(1fr) Daytona rl-platform benchmarks] })
#set text(font: ("Libertinus Serif", "New Computer Modern"), size: 9.7pt)
#set par(justify: false, leading: 0.58em)
#set heading(numbering: "1.")
#show heading.where(level: 1): it => block(above: 1.2em, below: 0.6em, text(12.5pt, weight: "bold", it))
#show heading.where(level: 2): it => block(above: 0.9em, below: 0.45em, text(10.5pt, weight: "bold", it))
#show table: set text(8.4pt)
#set table(stroke: 0.4pt + rgb("#bbbbbb"), inset: (x: 4.5pt, y: 3.2pt))
#show table.cell.where(y: 0): set text(weight: "bold")
#show table.cell.where(y: 0): set table.cell(fill: rgb("#eef1f5"))
#let w(x) = text(weight: "bold", fill: rgb("#1a6b2f"), x)
#let na = text(fill: gray, [—])
#let miss = text(fill: rgb("#a33a1a"), [not run])
#let note(body) = block(fill: rgb("#f3f5f8"), inset: 7pt, radius: 3pt, width: 100%, text(8.8pt, body))

#align(center)[
  #text(18pt, weight: "bold")[Where does Vera shine? — comparison report v2]
  #v(-0.4em)
  #text(11.5pt)[HQ Vera · AMD EPYC 9575F · AMD EPYC 9J45 (Turin) · AWS Graviton5, with the create-path fixes on]
  #v(-0.2em)
  #text(8.5pt, fill: gray)[Data as of 2026-10-14 23:30 UTC, from the three working sessions (Vera + 9575F, Turin, Graviton5). Supersedes the 15:05 status report.]
]

#note[
*What changed since the last report.* All four hosts now ran the *same Daytona build* (`f0611fa13` + bench patches) with the
four create-path fixes switchable by flag (#3260 init-disk no-fsync, #3261 cgroup pool, #3265 permanent neighbour entry,
#3269 API listen backlog 4096). The 9575F was brought onto that build and measured fixes off vs on; Vera and the 9575F were run at
2,000 sandboxes; Turin got the fixes and was rerun at 1k/2k, and its density ceiling was pushed to 9,750 live sandboxes.
Graviton5 was rerun fixes off vs on. *Green bold* = best value in a row. *Startup* = 1,000 (or 2,000) sandboxes created at
once by 16 client processes (`mpfleet.py`), probe `echo ready`. *Idle image* (`alpine:3.20`) measures the platform; the
*agent image* runs a ≈ 3–4 core-second job in every sandbox at boot, so it measures startup under CPU load.
]

= Verdict

#table(columns: (1.15fr, 0.75fr, 3fr),
  [Question], [Winner], [Evidence (fixes on unless noted)],
  [Throughput (jobs/s, dense agent ladder)], [#w[Vera] (Turin not yet measured)], [Vera *26.7* vs Graviton5 22.9 (+16 %) vs 9575F 8.0 (×3.3). Holds at 2,000 sandboxes: 26.1 vs 8.0. Fixes do not change throughput anywhere.],
  [Per-core speed], [#w[Vera]], [0.15 jobs/s per physical core vs 0.13 (9575F) and 0.12 (Graviton5); fastest single job (5.9 s vs 6.6–6.7 s).],
  [Platform startup, idle image, 1k], [#w[9575F] / Graviton5], [Typical create p50: Graviton5 *0.85 s*, 9575F *1.06 s*, Vera 1.57 s, Turin 2.35 s. All-ready: Graviton5 1.7–2.3 s, 9575F 2.1 s, Vera 2.7 s, Turin 3.9 s.],
  [Platform startup, idle image, 2k], [#w[9575F]], [p50 / all-ready: 9575F 2.4 / 4.6 s, Vera 2.9 / 6.6–7.2 s, Turin 3.5 / 7.1–7.2 s.],
  [Startup under load (agent image)], [#w[Turin]], [1k all-ready: Turin *7.9 s*, Graviton5 10–12 s, 9575F 19 s, Vera 22–28 s (one run 61 s). 2k: Turin *21 s*, Vera 50–55 s, 9575F 58–71 s.],
  [Density (live sandboxes)], [#w[Turin]], [Turin held *8,000* cleanly and peaked at 9,750 — stopped by the runner's heartbeat, not hardware. Vera and the 9575F ran 2,000 with ≤ 1 failure per 16,000 jobs.],
  [Reliability], [9575F, Turin, Graviton5], [0 failures in thousands of startups on x86 and Graviton5. Vera shows ≈ 0.2 % post-resume guest wedges (#3213) that hold "all ready" open.],
)

*Bottom line.* Vera shines on *sustained CPU-bound sandbox work*: the highest throughput measured so far and the fastest cores.
It does *not* lead on platform startup — with the fixes on, the 9575F and Graviton5 start sandboxes faster — nor on density.
The decisive gap is *Turin's throughput ladder*: Turin's agent-image bursts (a CPU-throughput proxy) are 2.5–3× faster than
Vera's, so Turin may match or beat Vera on throughput. Until that ladder runs, "Vera has the highest throughput" holds only
against Graviton5 and the EPYC 9575F / 9755.

= Hosts and build

#table(columns: (auto, 1fr, 1fr, 1fr, 1fr),
  [], [HQ Vera], [EPYC 9575F], [Turin (OCI phoenix-e6)], [Graviton5 (AWS)],
  [CPU], [NVIDIA Vera, 2 × 88 c, SMT2 (352 thr)], [AMD Zen 5, 1 × 64 c, SMT2 (128 thr)], [AMD EPYC 9J45, 2 × 96 c, SMT2 (384 thr)], [Neoverse-V3, 1 × 192 c, no SMT],
  [Memory], [1,479 GiB], [1,133 GiB], [2,267 GiB], [754 GiB],
  [Host kernel / pages], [6.17 nvidia / 64 KiB], [7.0 / 4 KiB], [6.17 oracle / 4 KiB], [6.17 aws / 4 KiB (64 KiB A/B done)],
  [Guest kernel], [6.12.34-rlp1 arm64], [6.8.12-rlp3 x86], [6.8.12-rlp3 x86], [6.12.34-rlp1 arm64],
  [`RLP_VM_MAXACK`], [256 (default)], [*2,048*], [256], [256],
  [Client HTTP pool / disk], [1,024 / 1 GiB], [1,024 / 1 GiB], [512 / 64 MiB], [1,024 / 1 GiB],
)
All four: Daytona `f0611fa13` + EROFS-4k (#1060) + `RLP_FC_SOCK_WAIT_MS=30000` (#3212) + the four create-path fixes behind
flags; Firecracker v1.16.1; daemon `rlp-rs-0.4.1`; `VM_CONCURRENCY=512`; balloon off; unpinned (whole box). Vera's and
Graviton5's runner binaries are byte-identical. Turin's #3269 patch was implemented independently (same flag, same effect).

= Startup

== 1,000 sandboxes, idle image — fixes off → on (seconds; reps separated by “/”)

#table(columns: (1.15fr, 1fr, 1fr, 1fr, 1fr),
  [Metric], [HQ Vera], [EPYC 9575F], [Turin], [Graviton5],
  [create p50, off], [2.07 / 2.39 / 2.32], [2.47 / 2.58 / 2.49], [3.72 / 3.68], [1.46 – 2.18],
  [*create p50, on*], [1.51 / 1.62 / 1.59], [1.10 / 0.98 / 1.09], [2.37 / 2.34], [#w[0.81 – 0.90]],
  [create p95, off], [3.30 / 3.76 / 3.46], [3.36 / 3.91 / 3.76], [7.71 / 7.65], [3.11 – 3.55],
  [*create p95, on*], [2.54 / 2.61 / 2.57], [1.59 / 1.60 / 1.57], [3.76 / 3.76], [#w[1.54 – 1.56]],
  [all ready, off], [4.70 / 3.86 / 3.66], [3.82 / 4.00 / 4.53], [7.95 / 7.96], [3.57 / 3.60 / 3.63],
  [*all ready, on*], [10.42#super[a] / 3.88 / 2.69], [2.26 / 2.12 / #w[2.05]], [3.88 / 3.87], [2.32 / #w[1.68] / 7.63#super[b]],
  [p50 gain from fixes], [−30 %], [−57 %], [−36 %], [≈ −60 %],
  [failures (on)], [1 in 3,000], [0], [0], [0],
)
#text(8.3pt)[#super[a] held open by one wedged guest (#3213/#3229). #super[b] 5 sandboxes waited 5.1–5.7 s for their toolbox at one
moment — a new tail seen only with fixes on, unexplained. Turin: all-ready 7.95 → 3.88 s (−51 %) closes the previous report's
open item: its ≈ 8 s was measured without the fixes. Its remaining dominant phase is snapshot `load` (≈ 0.5 s p50).]

== 1,000 sandboxes, agent image (startup under load) — fixes on

#table(columns: (1.15fr, 1fr, 1fr, 1fr, 1fr),
  [Metric], [HQ Vera], [EPYC 9575F], [Turin], [Graviton5],
  [create p50], [13.72 / 11.84 / 7.55], [6.60 / 6.63 / 8.28], [#w[2.54 / 2.51]], [5.43 – 5.49],
  [create p95], [23.90 / 26.05 / 21.73], [16.61 / 18.50 / 16.53], [#w[5.77 / 5.75]], [7.48 – 11.61],
  [all ready], [61.02#super[a] / 28.11 / 21.82], [18.85 / 19.14 / 18.77], [#w[7.84 / 7.88]], [10.11 / 10.79 / 12.31],
  [all ready, fixes off], [21.82 / 21.98 / 25.75], [20.35 / 20.24 / 20.56], [7.90 / 8.01 / 7.97], [10.10 / 11.77 / 11.83],
)
The fixes do not move agent-image numbers (≤ 3 %): the burst is bound by the in-guest boot job, i.e. by host CPU throughput.

== 2,000 sandboxes at once — fixes on

#table(columns: (1.4fr, 1fr, 1fr, 1fr, 0.8fr),
  [Metric], [HQ Vera], [EPYC 9575F], [Turin], [Graviton5],
  [idle: create p50], [3.00 / 2.79], [#w[2.46 / 2.34 / 2.40]], [3.50 / 3.47], miss,
  [idle: create p95], [6.40 / 6.57], [#w[3.63 / 3.57 / 3.57]], [6.89 / 6.79], miss,
  [idle: all ready], [6.59 / 7.23 / (lost run)#super[c]], [#w[4.62 / 4.56] / 17.65], [7.22 / 7.13], miss,
  [idle: all ready, fixes off], na, na, [23.22], miss,
  [agent: create p50], [29.4 / 27.5], [19.7 / 19.6], [#w[7.00]], miss,
  [agent: all ready], [50.2 / 54.5], [58.1 / 70.7], [#w[21.41]], miss,
  [failures], [2 (toolbox dial timeouts) + 1 lost run], [0], [0], na,
)
#text(8.3pt)[#super[c] one sandbox never answered; the client was killed after 20 min (wedged-guest pattern).]

= Throughput — dense agent ladder (jobs/s)

Published recipe: 45 jobs, 8 episodes per sandbox, hold-then-exec, 0.025 CPU (max 1), 64 MiB (max 4 GiB). Unpinned.

#table(columns: (1.6fr, 0.7fr, 0.7fr, 0.7fr, 0.7fr, 0.75fr, 1.6fr),
  [Host · arm], [176], [352], [704], [1,056], [2,000], [Note],
  [*HQ Vera · fixes on*], [15.17], [#w[26.65]], [25.62], na, [#w[26.11]], [2k: job p50 34 s, 1 failure in 16,000],
  [HQ Vera · fixes off], [15.0#super[d]], [26.67], [25.51], na, na, [],
  [*EPYC 9575F · fixes on*], [8.01], [8.05], [8.01], na, [8.03], [2k: job p50 239 s, max 553 s; 1 failure],
  [EPYC 9575F · fixes off], [8.13], [8.02], [8.04], na, na, [],
  [*Graviton5 · fixes on*], [23.62], [22.33], [22.89], na, na, [],
  [Graviton5 · fixes off (full ladder, 4 KiB)], [23.76], [22.63], [22.73], [22.79], [22.96], [0 failures to 2,000],
  [*Turin*], miss, miss, miss, miss, miss, [the decisive missing row],
  [Vera one socket (published Sep)], [11.8–13.7], [12.9–13.3], [12.8–13.1], [12.8–13.0], [12.7–14.2], [2k had 53–627 failures],
  [EPYC 9755 (published)], [9.6–10.0], [10.7–11.5], [10.7–11.3], [10.7–11.3], [10.9–12.0], [failures from 1,408],
)
#text(8.3pt)[#super[d] the fixes-off 176 rung read 1.47 jobs/s because of wedged guests; 15.0 is the clean rung on the same build.
Level 704 on Vera and the 9575F is from a rerun with a 600 s client timeout (120 s cut off healthy 9575F jobs).]

== Derived: per-core and per-thread rate (plateau)

#table(columns: (1.4fr, 0.8fr, 0.9fr, 0.8fr, 0.8fr, 0.9fr, 0.9fr),
  [Host], [Plateau jobs/s], [Cores / threads], [per core], [per thread], [Clock drop packed], [Single job, light load],
  [*HQ Vera*], [26.7], [176 / 352], [#w[0.152]], [0.076], [−6 %], [#w[5.9 s]],
  [Graviton5], [22.9], [192 / 192], [0.119], [#w[0.119]], [−3 %], [6.65 s],
  [EPYC 9575F], [8.0], [64 / 128], [0.126], [0.063], [−24 %], [6.7 s],
  [EPYC 9755 (published)], [≈ 11], [128 / 256], [0.086], [0.043], [—], [7.1 s],
  [Turin], miss, [192 / 384], [—], [—], [—], [—],
)
Platform overhead is 0.5–0.6 % of each job, so throughput is cores × per-core speed under full load. Vera's lead is per
*physical core* (with SMT); per hardware thread Graviton5 is ahead. Vera's 5.9 s single-job figure is from the September
one-socket data.

= Density

#table(columns: (1fr, 2.6fr),
  [Host], [Result],
  [*Turin*], [Bursts: 3,000 in 42.7 s, 4,000 in 81.9 s, 0 failures. Waves of 2,000 kept alive: *8,000 live with 0 failures*, each wave ready in 10–15 s. Peak *9,750 live* (9,946 Firecracker processes) with 1.7 TB memory free. Limits hit on the way, all configuration: 60 s create-pickup cap (4–5k), 1 GiB scratch reservation (6,742), `RLP_MAX_QUEUED_CREATES=8000`. Final stop: the runner's heartbeat starved, the API marked the runner lost and the lost-sweep marked 9,876 live VMs terminal (evidence added to #2459). First hardware limit (CPU reservation) extrapolates to ≈ 14,600.],
  [HQ Vera], [2,000 live in the throughput ladder: 1 failure in 16,000 jobs, peak memory 470 of 1,479 GiB (≈ 170 MiB per sandbox under load). Configured cap 3,000. Beyond that not measured.],
  [EPYC 9575F], [2,000 live: 1 failure in 16,000 jobs, 393 of 1,133 GiB (≈ 184 MiB per sandbox). Configured cap 3,000; at 3,000 jobs would take ≈ 375 s each and need a longer client timeout.],
  [Graviton5], [2,000 in the ladder with 0 failures (fixes off). Memory per sandbox ≈ 129 MiB idle / 215 MiB under load on 4 KiB pages; 64 KiB pages cost ≈ 8 % more (the earlier “2.3×” was a measurement error).],
)

= New findings in this round

- *The fixes help x86 more than Vera.* Idle-image p50 −57 % on the 9575F and ≈ −60 % on Graviton5 vs −30 % on Vera. With the
  fixes on, "Vera starts sandboxes faster" is reversed. Likely cause (unmeasured): the remaining create path is serial
  work where higher clocks win (9575F up to 5.0 GHz vs Vera 3.36 GHz).
- *Which fix matters depends on the host.* On Turin only #3260 (init-disk fsync, 313 → 9 ms) and #3261 (cgroup pool)
  moved anything; #3265 targets an arm64-only ~580 ms ARP stall and #3269 a listen-queue overflow that Turin never showed.
- *Turin's "8 s startup" is explained:* it was measured without the fixes. With them it is 3.9 s for 1k idle.
- *Density failure mode:* at ≈ 8–10k live sandboxes on one runner, the heartbeat starves and the lost-sweep orphans the
  whole fleet. Same class as #2459 (NATS-stall trigger there; host saturation here). Adoption verification is also capped
  at 4,096 VMs per host.
- *Graviton5:* 5 s toolbox waits in 5 of 3,000 fixes-on sandboxes (new, unexplained); pinning to one NUMA node halves
  throughput (cross-node memory costs 1.25× there vs 3.08× on Vera).
- *Measurement traps found and fixed:* a 120 s client read timeout reported healthy 9575F jobs as failures at 704; the SDK's
  `int(disk)*1024` silently reserved 1 GiB scratch per sandbox on Turin; a silently failed runner drop-in on Graviton5.

= Gaps and caveats

#table(columns: (1.6fr, 2.4fr),
  [Gap / caveat], [Effect on this report],
  [*Turin throughput ladder not run*], [The deciding number for "where Vera shines". Recommended next run (≈ 1 h, fixes on, 176 → 2,000).],
  [`RLP_VM_MAXACK` 2,048 on the 9575F vs 256 elsewhere], [Runner-slot wait is Vera's largest remaining startup step (421 ms). The 9575F's startup lead may partly be this setting; rerun Vera with 2,048 (≈ 15 min).],
  [Turin client: HTTP pool 512, 64 MiB disk], [Others used 1,024 and 1 GiB. Small effect expected on startup; not equalized.],
  [Graviton5: no 2k startup and no fixes-on ladder above 704], [Graviton5's 2k fixes-off ladder (22.96 jobs/s, 0 failures) stands in.],
  [Page size and preemption differ], [Vera 64 KiB + `preempt=none`; others 4 KiB; the AWS kernel cannot switch preemption.],
  [Fixes are not merged], [All four live only in the bench build. Fixes-on numbers must not be compared with stock EPYC data.],
  [Vera wedged guests (#3213, ≈ 0.2 %)], [Inflate Vera's all-ready numbers when they hit; reported with failure counts.],
  [EPYC 9755 unreachable], [Only its published (older-build) numbers appear.],
)

#v(0.4em)
#text(8.3pt, fill: gray)[Sources: `data/vera-hq-cell-20261014/BASELINE-{VERA,EPYC9575}-FIXES-20261014.md` and `.json`;
`data/phoenix-e6-cell-20261014/FINDINGS.md`, `runs.tgz`, `results-fixed.tgz` (Turin p50/p95 recomputed from the raw
per-sandbox JSONL); `data/graviton5-cell-20261014/FINDINGS.md` §5–6; `daniel-focus-here/public/` for published September data.]

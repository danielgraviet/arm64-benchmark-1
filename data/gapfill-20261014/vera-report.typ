#import "create-path-breakdown/tables.typ": t1kidle, t1kagent, t2k, twarm
#set document(title: "NVIDIA Vera sandbox benchmarks — consolidated report", date: datetime(year: 2026, month: 10, day: 15))
#set page(paper: "a4", margin: (x: 1.6cm, y: 1.7cm), numbering: "1 / 1",
  header: context { if counter(page).get().first() > 1 [#set text(8pt, fill: gray); NVIDIA Vera sandbox benchmarks — consolidated report #h(1fr) Daytona rl-platform · 2026-10-15] })
#set text(font: ("Libertinus Serif", "New Computer Modern"), size: 9.8pt)
#set par(justify: false, leading: 0.6em)
#set heading(numbering: "1.")
#show heading.where(level: 1): it => block(above: 1.3em, below: 0.65em, text(13pt, weight: "bold", it))
#show heading.where(level: 2): it => block(above: 1em, below: 0.5em, text(11pt, weight: "bold", it))
#show table: set text(8.5pt)
#set table(stroke: 0.4pt + rgb("#bbbbbb"), inset: (x: 4.5pt, y: 3.2pt))
#show table.cell.where(y: 0): set text(weight: "bold")
#show table.cell.where(y: 0): set table.cell(fill: rgb("#eef1f5"))
#let w(x) = text(weight: "bold", fill: rgb("#1a6b2f"), x)
#let r(x) = text(weight: "bold", fill: rgb("#a33a1a"), x)
#let na = text(fill: gray, [—])
#let miss = text(fill: rgb("#a33a1a"), [not run])
#let note(body) = block(fill: rgb("#f3f5f8"), inset: 8pt, radius: 3pt, width: 100%, text(9pt, body))

#align(center)[
  #v(1.5em)
  #text(20pt, weight: "bold")[NVIDIA Vera sandbox benchmarks]
  #v(-0.3em)
  #text(13pt)[Where Vera stands against AMD EPYC 9575F, AMD EPYC 9J45 (Turin) and AWS Graviton5]
  #v(-0.1em)
  #text(9pt, fill: gray)[Consolidated report v3 · adds the saved power and memory-bandwidth tests of 2026-10-15 · Turin bandwidth pending]
  #v(0.8em)
]

#block(fill: rgb("#edf6ef"), inset: 10pt, radius: 3pt, width: 100%)[
*Where Vera shines.* Vera combines fast compute with the ability to process large amounts of data across many sandboxes.
With *64 sandboxes working simultaneously*, it completed *roughly 3× as many memory-processing passes as Graviton5 and
6× as many as EPYC 9575F in the same time*—demonstrating its strength in demanding, data-intensive work.

#text(8.3pt)[*Measured basis:* about 134,000 / 45,000 / 22,500 passes in approximately 30 seconds, averaged over two
repetitions; zero failures at this level. Two-socket Vera versus single-socket peers. These are memory-processing passes,
not complete agent jobs. See #link(<memory-completions>)[Section 4: counts and source files].]
]

#note[
*Scope.* Daytona Linux sandboxes (Firecracker microVMs) on four bare-metal hosts using the same base source revision and
benchmark patches, with host-specific settings recorded below. Tests cover startup, agent-workload throughput, density,
streaming memory bandwidth and power. The memory test uses a separate workload and sandbox shape. Cross-host power meters
cover different components; those readings must not be presented as an equivalent whole-system efficiency comparison.
All four hosts are development benchmark cells, not production.
]

= Executive summary

*Vera's clearest measured advantage is now memory-streaming throughput inside sandboxes: about 2.1 TB/s across the
two-socket host, versus 0.60 TB/s on Graviton5 and 0.30 TB/s on the single-socket EPYC 9575F. Turin's bandwidth result is
still pending. Vera also retains the highest agent-workload throughput among the tested configurations.*

#table(columns: (1.2fr, 0.8fr, 3fr),
  [Question], [Leader], [Evidence],
  [Throughput (jobs/s)], [#w[Vera]], [Plateau: Vera 26.7 · Graviton5 22.9 · Turin 22.2 · EPYC 9575F 8.0. Same level, 2,000 sandboxes: Vera 26.1 · Graviton5 23.4 (Vera +12 %) · Turin 22.2 (+18 %) · 9575F 8.0. Vera beats dual-socket Turin with fewer cores (176 vs 192).],
  [Speed per core], [#w[Vera]], [0.152 jobs/s per physical core vs 0.126 (9575F), 0.119 (Graviton5), 0.116 (Turin): +21–31 %. Fastest single job (5.9 s vs 6.6–7.1 s). Per hardware thread Graviton5 leads (0.119 vs 0.076).],
  [Memory streaming], [#w[Vera] (Turin pending)], [Approximately 2.1 TB/s in the custom triad test: 3.5× Graviton5 and 7× the 9575F at their respective host plateaus. Two Vera sockets versus one on each comparison host; not a per-chip multiplier.],
  [Energy efficiency], [Not yet comparable], [At 2,000: Vera 42.3 J/job on its broad AP domain; Turin 44.1 and 9575F 47.7 J/job on CPU packages. Vera AP appears to include memory and regulator losses. Vera wall power and all Graviton5 power are unavailable.],
  [Throughput per socket], [Graviton5], [Graviton5 22.9 on one socket vs Vera ≈ 13 and Turin ≈ 11 per socket (sockets differ in core count: 192 / 88 / 96).],
  [Platform startup (idle image)], [9575F, Graviton5], [1k burst, typical sandbox, fixes on: Graviton5 0.85 s · 9575F 1.06 s · Vera 1.57 s · Turin 2.35 s.],
  [Platform startup at 2,000], [Graviton5], [Typical sandbox: Graviton5 1.5 s · 9575F 2.4 s · Vera 2.9 s · Turin 3.5 s.],
  [Startup under CPU load (agent image)], [Turin], [1k all ready: Turin 7.9 s · Graviton5 10–12 s · 9575F 19 s · Vera 22–28 s. 2k: Turin 21 s · Graviton5 27–29 s · Vera 50–55 s.],
  [Highest tested density], [Turin], [8,000 live cleanly, peak 9,750 before a liveness failure. Vera and the 9575F verified to 2,000; their maximum idle density was not tested, so this is not a proven capacity ratio.],
  [Observed failures], [Report per run], [Latest agent/power ladders: zero failures on Vera and the 9575F, including 2,000. Earlier runs each had one failure at 2,000. Memory ladder: 7 setup failures / 2,034 requests on Vera; 0 / 466 on the 9575F; 0 / 818 on Graviton5.],
)

*Bottom line.* There is now a large, workload-specific advantage to point to: streaming large arrays across many sandboxes
on the Vera host. This complements its roughly 18–20 % agent-throughput lead over Turin. It does not mean every agent
application becomes 3.5–7× faster, nor that Vera provisions sandboxes faster. Power results are encouraging but cannot yet
support a clean cross-platform or whole-server efficiency percentage. The next key comparison is Turin's memory ladder.

#pagebreak()
= Hosts and build

#table(columns: (auto, 1fr, 1fr, 1fr, 1fr),
  [], [HQ Vera], [EPYC 9575F], [Turin (OCI phoenix-e6)], [Graviton5 (AWS m9gd)],
  [CPU], [NVIDIA Vera, 2 × 88 cores, SMT2 (352 threads)], [AMD Zen 5, 1 × 64 cores, SMT2 (128)], [AMD EPYC 9J45, 2 × 96 cores, SMT2 (384)], [Neoverse-V3, 1 × 192 cores, no SMT],
  [Memory], [1,479 GiB], [1,133 GiB], [2,267 GiB], [754 GiB],
  [Host kernel / pages], [6.17 nvidia / 64 KiB, `preempt=none`], [7.0 / 4 KiB], [6.17 oracle / 4 KiB], [6.17 aws / 4 KiB],
  [Guest kernel], [6.12.34 arm64], [6.8.12 x86], [6.8.12 x86], [6.12.34 arm64],
  [Storage], [1 NVMe], [NVMe RAID], [1 NVMe (RAID10 removed)], [1 NVMe instance store],
  [`RLP_VM_MAXACK`], [256], [*2,048*], [256], [256],
)
Every host: Daytona `f0611fa13` + EROFS-4k (#1060) + 30 s Firecracker socket wait (#3212) + the four create-path fixes behind
flags; Firecracker v1.16.1; daemon `rlp-rs-0.4.1`; balloon off; whole box, unpinned. Startup/agent shape: 1 vCPU, 0.025 CPU,
64 MiB memory guarantee. Memory-test shape: 1 vCPU, 1 GiB memory guarantee, 4 GiB maximum. Startup client: `mpfleet.py`
with 16 processes. Results are fixes-on unless stated; no power caps were changed for the new tests.

= Results

== Startup — 1,000 sandboxes at once

#table(columns: (1.5fr, 1fr, 1fr, 1fr, 1fr),
  [Metric (s)], [HQ Vera], [EPYC 9575F], [Turin], [Graviton5],
  [Idle image: typical (p50), fixes off → on], [2.26 → 1.57], [2.51 → #w[1.06]], [3.70 → 2.35], [≈ 2.2 → #w[0.85]],
  [Idle image: slow (p95), on], [2.54–2.61], [1.57–1.60], [3.76], [#w[1.54–1.56]],
  [Idle image: all ready, on], [2.7–3.9#super[a]], [#w[2.05–2.26]], [3.87–3.88], [1.68–2.32#super[b]],
  [Agent image: all ready, on], [21.8–28.1#super[a]], [18.8–19.1], [#w[7.84–7.88]], [10.1–12.3],
  [Failures], [1 in 3,000 (idle), 2 in 3,000 (agent)], [0], [0], [0],
)
#text(8.3pt)[#super[a] one run held open by a wedged guest (10.4 s idle, 61 s agent). #super[b] one run 7.6 s: 5 sandboxes with 5 s toolbox waits (new, fixes-on only).]

== Startup — 2,000 sandboxes at once

#table(columns: (1.5fr, 1fr, 1fr, 1fr, 1fr),
  [Metric (s)], [HQ Vera], [EPYC 9575F], [Turin], [Graviton5],
  [Idle: p50 / p95], [2.9 / 6.5], [2.4 / 3.6], [3.5 / 6.8], [#w[1.5 / 3.0]],
  [Idle: all ready], [6.6–7.2 (one run lost)], [4.6 (one run 17.7)], [7.1–7.2], [#w[4.4] (one run 15.4)],
  [Agent: p50 / all ready], [28.5 / 50–55], [19.7 / 58–71], [#w[7.0 / 21.4]], [12.0 / 27–29],
  [Failures], [2 + 1 lost run], [0], [0], [0],
)

#pagebreak()
== Throughput — dense agent ladder (jobs/s)

Published recipe: workload parameter `--n 45`, eight episodes per sandbox, hold-then-exec, 0.025 CPU (max 1),
64 MiB (max 4 GiB). A level with c sandboxes executes 8c jobs, not 45 × 8c.

#table(columns: (1.8fr, 0.6fr, 0.7fr, 0.7fr, 0.7fr, 0.7fr, 0.75fr, 0.7fr),
  [Host], [44], [176], [352], [704], [1,056], [2,000], [failures],
  [*HQ Vera (new power run)*], [6.66], [14.54], [#w[26.29]], [#w[25.52]], na, [#w[26.25]], [0],
  [Graviton5], [5.7#super[c]], [23.6], [22.3], [22.9], [22.5], [23.4], [0],
  [Turin], [5.5], [17.9], [20.2], [22.3], [22.2], [22.2], [0 (11 levels)],
  [EPYC 9575F (new power run)], [5.91], [7.98], [7.93], [8.03], na, [8.02], [0],
  [Vera one socket (published Sep)], [6.0–6.6], [11.8–13.7], [12.9–13.3], [12.8–13.1], [12.8–13.0], [12.7–14.2], [53–627 at 2,000],
  [EPYC 9755 (published)], [4.3–5.5], [9.6–10.0], [10.7–11.5], [10.7–11.3], [10.7–11.3], [10.9–12.0], [from 1,408],
)
#text(8.3pt)[All fixes on except #super[c]. Latest Vera and 9575F power runs completed 26,208 jobs each with zero failures and matching
checksums, retaining the earlier throughput ranking. Earlier at 2,000, each had one toolbox-network failure in 16,000 jobs;
the clean repeat does not erase those incidents. At 2,000 the latest job p50 is 32.0 s on Vera and 237.7 s on the 9575F;
Turin and Graviton5 recorded about 80 and 84 s.]

#table(columns: (1.4fr, 0.8fr, 0.8fr, 0.7fr, 0.7fr, 0.9fr, 0.8fr),
  [Derived], [Plateau jobs/s], [Cores / threads], [Per core], [Per thread], [Single job, light load#super[e]], [Clock drop packed#super[f]],
  [HQ Vera], [26.3], [176 / 352], [#w[0.149]], [0.075], [#w[5.922 s]], [−0.6 %],
  [Graviton5], [22.9], [192 / 192], [0.119], [#w[0.119]], [6.65 s], [−3 %],
  [Turin], [22.2], [192 / 384], [0.116], [0.058], [7.06 s], [−21 %],
  [EPYC 9575F], [8.0], [64 / 128], [0.125], [0.063], [6.709 s], [about −15 %],
  [EPYC 9755 (published)], [≈ 11], [128 / 256], [0.086], [0.043], [7.1 s], [—],
)
#text(8.3pt)[#super[e] job p50 at c=44. Vera's 5.922 s and the 9575F's 6.709 s are now confirmed on the current benchmark build;
the 9755 remains historical. #super[f] Vera and the 9575F use the same new busy-core sampler: 3.39 → 3.37 GHz and
4.33 → 3.65–3.69 GHz. These supersede the earlier −6 % / −24 % figures for these runs. Turin's single-busy-core comparison
and Graviton5's PMU method differ; do not attribute the throughput gap quantitatively to clock loss. The 26.7 jobs/s
Vera result remains a prior measurement; the new run reproduces about 26.3 jobs/s.]

== Density

- *Turin:* bursts of 3,000 (42.7 s) and 4,000 (81.9 s) with 0 failures; waves of 2,000 kept alive to *8,000 with 0 failures*
  (each wave ready in 10–15 s); peak *9,750* alive with 1.7 TB free. Configured limits found on the way: the API's 60 s
  create-pickup cap, the scratch reservation (1 GiB per sandbox → 6,742), `RLP_MAX_QUEUED_CREATES` = 8,000. The final stop
  was the runner's heartbeat starving under load: the API marked the runner lost and its lost-sweep marked 9,876 live
  sandboxes terminal, orphaning them (evidence added to #2459).
- *Vera / 9575F:* 2,000 alive, ≤ 1 failure per 16,000 jobs, ≈ 170–184 MiB host memory per sandbox under load. Configured cap 3,000.
- *Graviton5:* 2,000 with 0 failures in the startup test and the ladder (peak 504 of 754 GiB in the ladder). 64 KiB host pages cost ≈ 8 % more memory per sandbox.
- *Not measured:* idle-density ceiling on Vera and Graviton5.

#pagebreak()
= New result: memory streaming inside sandboxes <memory-streaming>

The same custom C triad kernel (`a = b + 3c`) runs inside concurrent one-vCPU sandboxes. Each sandbox allocates three
arrays of 2^24 doubles, 384 MiB total; initialization, compilation and a warm pass precede the timed 30-second loop.
Two repetitions per level. All completed runs used `buildpack-deps:bookworm`, GCC 12.2 and `-O3`.
The originally proposed `gcc:14` image failed during guest boot on this old bench build because of unquoted environment
values; those failed attempts are excluded. This image problem is already fixed upstream (issue #1554).

Reported GB/s is *effective application traffic*: 24 bytes per element per pass (two reads and one write), summed over
successful concurrent sandboxes. It excludes write-allocation traffic and is not a hardware DRAM-counter measurement
or an official STREAM submission. This measures streaming bandwidth available to sandboxed code, not application
completion time or the maximum theoretical bandwidth of a CPU.

#table(columns: (0.85fr, 1.2fr, 1.2fr, 1.2fr, 0.9fr),
  [Sandboxes requested], [HQ Vera GB/s (r1 / r2)], [Graviton5 GB/s (r1 / r2)], [EPYC 9575F GB/s (r1 / r2)], [Turin],
  [1], [72.46 / 72.06], [57.91 / 56.99], [45.13 / 47.08], [Pending],
  [8], [550.83 / 570.34], [365.13 / 337.65], [262.40 / 260.91], [Pending],
  [32], [1,019.21 / 1,014.57], [594.21 / 593.86], [299.84 / 299.71], [Pending],
  [64], [1,743.63 / 1,852.51], [#w[603.94 / 603.87]], [301.45 / 302.11], [Pending],
  [128], [#w[2,123.72 / 2,125.37] (127 ran in each)], [571.64 / 572.01], [#w[305.24 / 305.11]], [Pending],
  [176], [2,099.44 / 2,108.42 (174 / 176 ran)], [582.41 / 582.17], [Not run], [Pending],
  [256], [2,070.37 / 2,067.67 (256 / 255 ran)], [Not run], [Not run], [Pending],
  [352], [1,356.90 / 1,406.26 (351 ran in each)], [Not run], [Not run], [Pending],
)

*Where Vera clearly stands out.* The two-socket host sustained about 2.1 TB/s at 128–256 requested sandboxes. Compared
with each host's measured plateau, that is approximately *3.5× Graviton5* (0.60 TB/s) and *7× the 9575F* (0.305 TB/s).
Those are whole-host comparisons: Vera has two sockets, Graviton5 and the 9575F one each. At 64 sandboxes all requests
succeeded: Vera averaged 1.80 TB/s versus 0.604 and 0.302 TB/s. A fully successful 256-sandbox Vera repetition reached
2.07 TB/s, so the large advantage does not depend on the partially populated peak repetitions.

*Same sandbox count, more work completed.* At 64 sandboxes, every request succeeded on every host. Each completed pass
reads and writes a combined 384 MiB across the same three arrays; the counts below come directly from the `passes`
fields, rather than from a projected application speedup. <memory-completions>

#table(columns: (1.15fr, 1.3fr, 1fr, 1fr),
  [Server], [Completed passes (r1 / r2)], [Mean passes per roughly 30 s], [Vera's ratio],
  [HQ Vera], [129,935 / 138,044], [133,989.5], [—],
  [Graviton5], [45,021 / 45,015], [45,018], [2.98×],
  [EPYC 9575F], [22,479 / 22,527], [22,503], [5.95×],
)
#text(8.3pt)[Source: `c64-r1.jsonl` and `c64-r2.jsonl` in the valid memory-run directories within `vera-power-mem.tgz`,
`mem-ladder-20261015.tgz` (Graviton5), and `epyc9575-power-mem.tgz`. Each sandbox's timed kernel ran for 30.00–30.08 s.
The result measures repeated memory-processing work at fixed concurrency, not sandbox creation speed, capacity or complete agent jobs.]

*Single sandbox:* averages are 72.3 GB/s (Vera), 57.5 (Graviton5) and 46.1 (9575F): about 26 % and 57 % higher on Vera.
These measure this compiled streaming kernel, not a universal single-core-speed multiplier. Vera falls to about 1.38 TB/s
at 352 requested sandboxes; maximum concurrency is not the maximum-bandwidth operating point. The data do not isolate
the cause of that fall (scheduling, SMT, placement and power limits may all matter).

*Validation and failures.* The archives contain byte-identical C source. Every successful record has the expected array
size, checksum and bandwidth arithmetic; run summaries match the sums of those records. Vera had 7 setup failures in
2,034 requested sandboxes (0.34 %), rather than the write-up's approximate denominator of 1,042. There were no failures
during the timed kernels. Graviton5 completed 818/818; the 9575F 466/466. Failed setup attempts are not silently counted
as running sandboxes in the rates above.

*Timing correction.* Arm64 snapshot guests retained stale wall clocks, so guest timestamps cannot be aligned directly
with host power samples. We use host exec-send/response times. Those times plus the measured kernel durations bound
the common timed overlap to at least 29.08 s on Vera, 29.45 s on Graviton5 and 28.53 s on the 9575F, out of about 30 s.
Small execution-start differences remain; these are not perfectly hardware-synchronized launches. Power is sampled
over the interior host-side window, avoiding the stale-clock error in the kit's original report.

#pagebreak()
= New result: power and energy per job

The latest power ladders reproduce high agent throughput with zero failures on Vera and the 9575F. Their 352 / 704 /
2,000 levels are shown below alongside Turin's preserved ladder plus its new idle baseline. Energy per job is average
measured watts divided by completed jobs per second; jobs/s per kW is its reciprocal scaled by 1,000.

*Important correction to the run-kit instructions:* Vera's *AP Power is not established as CPU-package-only power*.
The ACPI tables name the sensors but expose no metered-device mapping. The separate meter log is consistent with AP
covering CPU, SoC, LPDDR and additional rails/regulator losses; Total is the broader, capped socket-module domain.
AMD package power excludes external DRAM and regulator losses. The column originally named `processor_w` therefore
does not have an equivalent boundary across architectures.

#table(columns: (0.6fr, 0.85fr, 1.4fr, 0.65fr, 0.75fr, 0.8fr, 0.65fr),
  [Sandboxes], [Host], [Power scope], [Jobs/s], [Watts], [Jobs/s per kW], [J/job],
  [352], [Vera], [AP, both sockets], [26.29], [1,108], [23.7], [42.1],
  [352], [9575F], [CPU package], [7.93], [374], [21.2], [47.2],
  [352], [Turin], [Two CPU packages], [20.15], [936], [21.5], [46.4],
  [704], [Vera], [AP, both sockets], [25.52], [1,079], [23.6], [42.3],
  [704], [9575F], [CPU package], [8.03], [379], [21.2], [47.2],
  [704], [Turin], [Two CPU packages], [22.27], [972], [22.9], [43.6],
  [2,000], [Vera], [AP, both sockets], [26.25], [1,109], [23.7], [42.3],
  [2,000], [9575F], [CPU package], [8.02], [382], [21.0], [47.7],
  [2,000], [Turin], [Two CPU packages], [22.15], [977], [22.7], [44.1],
)

*Do not rank energy efficiency from this table as if its scopes were equal.* It is encouraging that Vera's broader
meter gives similar or better joules per job, but the exact boundary is unconfirmed. The meter study also constructs a
CPU Rail Output + SoC estimate: approximately 911 / 806 / 863 W on Vera at 352 / 704 / 2,000, or 29–32 jobs/s per kW
and 32–35 J/job. This is a diagnostic estimate, not a vendor-validated equivalent to AMD's package sensor.

#table(columns: (1fr, 1.6fr, 1.6fr, 1.6fr),
  [Host], [Idle], [Loaded / module or wall], [What is missing],
  [Vera], [225 W AP; 282 W Total], [1,159–1,192 W Total at the three plateau levels; about 45 J/job], [Whole-server wall power; authoritative Vera rail definitions],
  [9575F], [54 W package; 133 W DCMI wall], [692–717 W wall; about 87–89 J/job], [DRAM-only sensor; short memory-test wall samples are lagged],
  [Turin], [178 W, two packages], [About 970 W package at plateau], [DRAM and wall power],
  [Graviton5], [Not exposed], [Not exposed], [All power telemetry unavailable through this AWS instance],
)

Vera Total excludes other server components and PSU loss; it cannot be compared with the 9575F wall meter to claim
“twice the system efficiency.” For memory streaming, the saved AP/package ratios are about 1.9–2.4 GB/s/W on Vera at
128–256 sandboxes versus 0.83–1.07 on the 9575F at its plateau. The same unequal-scope limitation applies. There is no
Graviton5 GB/s/W figure and no complete Turin memory result.

*Clock and power caps.* The same busy-core sampling method reports Vera at 3.39 GHz at c=44 and 3.37 GHz packed
(about −0.6 %), versus 4.33 → 3.65–3.69 GHz on the 9575F (about −15 %). Vera's Total meter approaches its 600 W per-socket
cap; stable sampled frequency does not mean no power throttling. Turin's older −21 % and Graviton5's −3 % use different
methods and remain indicative, not a controlled causal explanation of throughput differences.

Power windows are inferred from sampled JSONL-summary arrival and the recorded execution durations. They are suitable
for approximate plateau averages, not exact per-job energy accounting; they have sampling and phase-boundary error.
The memory runs' roughly 24-second interior windows contain too few fresh BMC readings for a reliable wall-power result.

#pagebreak()
= Where the create time goes

From `POST /vms` to the first command answered, per sandbox; client timestamps joined with the runner's per-sandbox log on
each host (same clock). Full tables in the appendix.

#table(columns: (2.4fr, 1fr, 1fr, 1fr, 1fr),
  [1,000 at once, idle image, fixes on (ms, p50)], [HQ Vera], [EPYC 9575F], [Graviton5], [Turin],
  [A · API accepts the create (overlaps B)], [285], [652], [196], [252],
  [B · request → runner starts the job (queue for a slot)], [715], [411], [321], [865],
  [D2 · scratch + init-disk copy], [11], [38], [14], [10],
  [D3 · Firecracker spawn + API socket], [#r[208]], [83], [83], [26],
  [D4 · snapshot load + resume], [32], [39], [16], [#r[484]],
  [D6 · cgroup, register, entrypoint trigger], [124], [155], [78], [17],
  [D · runner clone total], [441], [413], [246], [706],
  [E · running event → client sees it (SDK polling)], [319], [220], [182], [346],
  [*Total, request → first command done*], [*1,591*], [*1,076*], [*889*], [*2,353*],
)

- *Idle host, one sandbox:* ≈ 88 ms on Vera (API ≈ 5 ms, runner ≈ 60 ms with Firecracker spawn 39 ms, event back 2 ms,
  first command 21 ms). The harness reports ≈ 275 ms everywhere because its SDK first polls after 250 ms.
- *In a burst the time is waiting:* for a runner slot (B; 256 in flight by default) and for the next SDK poll (E).
- *Host-specific slow steps:* Vera's Firecracker spawn (208 ms, 2.5–8× the others) and Turin's snapshot load (484 ms vs
  16–39 ms) — both unexplained and the obvious next investigations.

= Fixes that changed the results

== The four create-path fixes (each behind a flag; measurement builds, not merged)

#table(columns: (1.4fr, 2fr, 2fr),
  [Fix], [What it changes], [Effect],
  [#3260 `RLP_INITDISK_MODE=nofsync`], [No fsync of the 16 MiB per-sandbox init disk (16 GB written per 1k burst)], [D2: 352 ms (Vera), 567 ms (Graviton5), 1,293 ms (9575F) → 10–38 ms],
  [#3261 `RLP_CGROUP_POOL=1400`], [Per-sandbox cgroups pre-created at runner start], [188–201 ms → 24 ms on Vera],
  [#3265 `RLP_NEIGH_PERMANENT=1`], [Permanent neighbour entry: removes a 580 ms post-resume stall on arm64], [Vera single-create p99 658 → 73 ms],
  [#3269 `RLP_API_LISTEN_BACKLOG=4096`], [API listen queue 128 → 4,096], [Dropped connections 424–687 → 0 per burst],
)
Together: 1k idle startup p50 −30 % on Vera, −57 % on the 9575F, ≈ −60 % on Graviton5, −36 % on Turin (all ready 7.95 → 3.88 s).
No change to agent-image startup or throughput. On Turin only #3260 and #3261 mattered; #3265 and #3269 fix symptoms Turin never had.

== Other fixes behind earlier result changes

#table(columns: (1.8fr, 3fr),
  [Fix], [Effect],
  [Sudo storm (#1754, upstream)], [BM pair at 1,800 sandboxes: 1,720 of 1,880 failed → 0 of 3,600; p50 260 → 20 s],
  [Firecracker socket wait 3 → 30 s (#3212)], [Spawn timeouts and runner self-cordons → 0 (Vera 177–304 per 1k); medians unchanged],
  [Balloon off on 64 KiB-page hosts (#1066)], [Guest memory corruption 14/64 → 0/544],
  [EROFS 4 KiB blocks (#1060)], [Vera creates: always failing → working],
  [Busy loop `rlp-cpu-weight-floor.sh` stopped (9575F)], [1k median 18.6 → 9.7 s; it ran during the published 2 Oct runs],
  [ARP `gc_thresh3` 1,024 → 65,536], [704 sandboxes: 1,324 failures → 0; peak 55.9 → 62.7 jobs/s],
  [Memory burst cap 32 GiB → 512 MiB], [2,112 sandboxes: 14.4 → 137.6 jobs/s; OOM kills 406 → 0],
  [E2B huge pages released (HQ Vera)], [Usable memory ~2 GB → 1.44 TB],
  [Hostname in `/etc/hosts`], [`sudo` 113 s → 0.2 s; runner could not start without it],
  [Client: 16 processes, open-files limit, SDK disk rounding], [“Accept” 2.9–5.8 → 0.12–0.5 s; EMFILE failures → 0; Turin's density wall at 6,742 removed],
)

#pagebreak()
= Methodology corrections

- *The agent image measures its own workload, not startup.* Each sandbox burns 3–4 core-seconds at boot; with an idle image the
  platform starts 1,000 sandboxes in ≈ 4 s (fixes off) on Vera, the 9575F and Graviton5. Daytona's own CPU cost is ≈ 28 ms per sandbox.
- *“Control plane accepts the request” was the single-process Python client*, not the API.
- *Placement is workload-specific.* Pinning improved Vera's agent-image startup burst, while reducing its sustained
  throughput to roughly one socket's share. Graviton5 also lost about half its throughput when restricted to one node.
  This is not a universal NUMA rule; Turin's one-socket throughput arm has not been measured.
- *Published-data corrections:* the 9575F 2k mean kept a 151 s outlier and was taken with the busy loop on; the 9755's 88.4 s
  drops a run (all four: 91.1 s); Vera's published 2k throughput point had 53–627 failures.
- *Measurement traps:* a second operator on HQ Vera invalidated one night of runs (rule: one operator per box); a 120 s client
  timeout reported healthy 9575F jobs as failures; SDK polling adds ≈ 0.2–0.35 s to every startup number.
- *Turin's “8 s startup” is explained:* it was measured without the fixes; with them it is 3.9 s.
- *The power kit mislabelled the scopes.* Its `processor_w` combines Vera AP readings or AMD package readings, which
  do not cover the same components. The new report labels the actual sensor domain instead.
- *Guest wall clocks are unsuitable for aligning restored sandboxes with host telemetry.* Memory-test power is now
  calculated from host-side RPC windows; the kernel itself is timed with a monotonic clock.

= Host page size (64 KiB vs 4 KiB)

Guests always use 4 KiB pages; the host page size only affects how the host backs and maps guest memory. On Graviton5 (same
chip, same kernel version, one reboot) 64 KiB pages changed throughput by +1.5 % (noise), startup by +0.5 s and single-job time
not at all, and cost ≈ 8 % more host memory per sandbox. The benchmark workload is CPU-bound with a small memory footprint, so
cheaper address translation saves little. *On Vera itself this was never measured* — its 4 KiB kernel is installed but unused —
so a gain there is unlikely for this workload but not ruled out.

= What the data supports publicly

#table(columns: (2.2fr, 0.7fr, 2.4fr),
  [Claim], [Verdict], [Basis],
  [Vera delivers high sustained throughput for CPU-intensive agent work], [#w[supported]], [Highest jobs/s of all hosts, flat from 352 to 2,000 sandboxes.],
  [Vera outperforms the tested x86 and Arm servers on agent-workload throughput], [#w[supported], with scope], [At 2,000 in the latest runs: 26.25 vs 22.15 / 23.38 / 8.02 jobs/s (Turin / Graviton5 / 9575F). Configuration and socket counts must accompany numerical comparisons.],
  [Fast per-core performance on this workload], [#w[supported]], [Higher jobs/s per physical core; the current-build c=44 run confirms the 5.922 s per-job result. Physical-core normalization includes SMT's benefit.],
  [Sustains that speed with thousands of tasks running], [#w[supported] as aggregate throughput], [Throughput flat to 2,000; individual jobs get slower as more share the CPU (34 s per job at 2,000), as on every host.],
  [Faster sandbox startup], [#r[not supported]], [Graviton5 and the 9575F start sandboxes faster; Turin under CPU load.],
  [“Instantly”, “without interruption”, “without trading responsiveness for scale”], [#r[not supported]], [Absolute claims; Vera had rare guest wedges (#3213) and per-job latency rises with load.],
  [High streaming bandwidth is available inside Vera sandboxes], [#w[supported]], [About 2.1 TB/s aggregate in this triad microbenchmark; approximately 3.5× Graviton5 and 7× the 9575F as configured. Turin pending.],
  [Memory-intensive agent applications will run 3.5–7× faster], [#r[not established]], [A streaming microbenchmark measures a capability. End-to-end workloads include compute, I/O, allocation, tool calls and other costs.],
  [Vera is X% more energy-efficient as a whole server], [#r[not established]], [Power-domain boundaries differ; Vera whole-server power is unavailable and Graviton5 exposes no power telemetry.],
)

*Defensible announcement wording:* “Vera combines strong per-core compute performance with high streaming memory
bandwidth available inside isolated sandboxes, supporting high aggregate throughput across concurrent agent workloads.”
The bandwidth result strengthens this positioning; it does not establish instant provisioning, unchanged per-task
latency as concurrency increases, or interruption-free operation.

#pagebreak()
= Open questions and next tests

#table(columns: (1.6fr, 2.4fr, 0.7fr),
  [Test], [Why], [Time],
  [*Finish Turin's memory ladder*], [The missing modern x86 bandwidth comparison. The owner reports a reboot is needed; that remains pending authorization in that session.], [After recovery],
  [*Validate comparable power boundaries*], [Get Vera-specific sensor definitions and equivalent package + memory or whole-server readings before stating an efficiency percentage.], [Vendor/telemetry work],
  [*Real memory-intensive application*], [Test a representative data-processing or agent workload with timed compute separate from data generation; the triad result is a microbenchmark capability, not an application speedup.], [New test design],
  [Repeat bandwidth with placement and compiler controls], [Confirm per-socket behavior, vectorization and larger array sizes; investigate the bandwidth fall at 352 Vera sandboxes.], [Follow-up runs],
  [Vera full ladder and repeated matched rungs], [The new run adds c=44 and a clean 2,000 repeat, but still does not cover all eleven levels or establish statistical confidence intervals.], [≈ 1 h/run],
  [Clock under load, one method across all hosts], [Vera and the 9575F now have a common busy-core method; Turin and Graviton5 still differ.], [With future runs],
  [Equalize `RLP_VM_MAXACK` (2,048 on Vera)], [The 9575F's startup lead may partly be its larger in-flight cap.], [≈ 15 min],
  [Vera 4 KiB vs 64 KiB host pages], [Settles whether the large-page kernel helps Vera at all.], [≈ 1.5 h],
  [Vera Firecracker spawn / Turin snapshot load], [The two unexplained slow create steps.], [≈ 0.5 day each],
  [#3213 guest wedges, #2459 runner heartbeat at high density], [Reliability on Vera; density ceiling above ≈ 8,000.], [platform work],
)

== Reproducibility and reporting boundaries

The new tables use the valid run directories named in the source write-ups, excluding aborted image boots and earlier
memory attempts. The verification script reads those archived results, reconciles all sandbox counts, checks each
triad checksum and rate calculation, and records archive/source hashes. It does not run workloads or alter hosts.
The historical startup and per-step appendix retain their original measurements; the new power runs refresh agent
throughput and light-load job time, not startup timings.

Numerical comparisons describe the tested systems and recipes. They do not control socket count, memory technology,
host page size, every tuning flag or compiler target behavior. The memory test has two repetitions per level; no
statistical confidence interval or population-wide failure rate is inferred. Power meters are reported by name and
scope, and the missing Turin bandwidth result stays missing until that host's run completes.

The report source, `audit-power-memory.py`, its generated JSON, and `POWER-MEMORY-UPDATE-20261015.md` are saved beside
the PDF. The earlier PDFs remain as dated records; this v3 report supersedes their power-scope assumptions and the
statement that memory bandwidth had not yet been tested.

#set page(flipped: true, margin: (x: 1.3cm, y: 1.4cm))
#show table: set text(7.8pt)
#set table(inset: (x: 3.5pt, y: 2.6pt))

= Appendix — create path, per step (ms, p50 / p90)

Steps: *A* API accepts the create (overlaps B) · *B* request sent → runner starts the job · *C* admission, image, template ·
*D1* netns · *D2* scratch + init disk · *D3* Firecracker spawn · *D4* snapshot load + resume · *D5* guest toolbox accepts ·
*D6* cgroup, register, trigger · *E* running event → client (SDK polling) · *F* first command. Medians of steps do not add up
exactly to the median total. Turin: fixes-on only (its fixes-off runner log rotated out).

== 10 sandboxes at once (low load, harness warm-up runs)
#twarm

#pagebreak()
== 1,000 at once, idle image
#t1kidle

#pagebreak()
== 1,000 at once, agent image
#t1kagent

#pagebreak()
== 2,000 at once, fixes on (idle: first three columns; agent: last three)
#t2k

#v(0.6em)
#text(8pt, fill: gray)[Sources: `vera-hq-cell-20261014/` (BASELINE-VERA/EPYC9575-FIXES, CREATE-PATH-STEPS, FINDINGS), `phoenix-e6-cell-20261014/FINDINGS.md`,
`graviton5-cell-20261014/FINDINGS.md`, `gapfill-20261014/create-path-breakdown/` (runner journals, `analyze.py`, `agg.json`),
`daniel-focus-here/public/` (published September data). New sources: `vera-hq-cell-20261014/power-mem-20261015/RESULTS.md`,
`vera-power-mem.tgz`, `epyc9575-power-mem.tgz`; `graviton5-cell-20261014/mem-ladder-20261015.tgz`;
`phoenix-e6-cell-20261014/power-mem/` (idle and ladder samples). Independent arithmetic/coverage checks and archive hashes:
`gapfill-20261014/power-memory-audit-20261015.json`, generated by `audit-power-memory.py`.
The NVIDIA Grace Performance Tuning Guide's Power Telemetry section describes Grace power boundaries; it is useful background,
not a Vera-specific sensor contract: https://docs.nvidia.com/grace-perf-tuning-guide/power-thermals.html.]

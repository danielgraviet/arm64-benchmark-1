#import "tables.typ": *
#set document(title: "Sandbox create path — per-step breakdown", date: datetime(year: 2026, month: 10, day: 15))
#set page(paper: "a4", flipped: true, margin: (x: 1.4cm, y: 1.4cm), numbering: "1 / 1",
  header: context { if counter(page).get().first() > 1 [#set text(8pt, fill: gray); Sandbox create path — per-step breakdown #h(1fr) Daytona rl-platform benchmarks · 2026-10-15] })
#set text(font: ("Libertinus Serif", "New Computer Modern"), size: 9.6pt)
#set par(justify: false, leading: 0.58em)
#set heading(numbering: "1.")
#show heading.where(level: 1): it => block(above: 1.1em, below: 0.55em, text(12.5pt, weight: "bold", it))
#show heading.where(level: 2): it => block(above: 0.85em, below: 0.45em, text(10.5pt, weight: "bold", it))
#show table: set text(8pt)
#set table(stroke: 0.4pt + rgb("#bbbbbb"), inset: (x: 4pt, y: 2.8pt))
#show table.cell.where(y: 0): set text(weight: "bold")
#show table.cell.where(y: 0): set table.cell(fill: rgb("#eef1f5"))
#let note(body) = block(fill: rgb("#f3f5f8"), inset: 7pt, radius: 3pt, width: 100%, text(8.8pt, body))
#let red(x) = text(weight: "bold", fill: rgb("#a33a1a"), x)

#align(center)[
  #text(18pt, weight: "bold")[Sandbox create path — how long each step takes]
  #v(-0.4em)
  #text(11pt)[Daytona API, JetStream, runner, Firecracker and guest, per sandbox, on HQ Vera, EPYC 9575F, Turin and Graviton5]
  #v(-0.2em)
  #text(8.5pt, fill: gray)[Benchmark runs of 2026-10-14 (same build `f0611fa13` + bench patches on every host); fixes = #3260 init-disk no-fsync, #3261 cgroup pool, #3265 permanent neighbour, #3269 API backlog 4096.]
]

= Summary

#grid(columns: (1fr, 1fr), gutter: 14pt,
[
*One sandbox on an idle host takes ≈ 85–90 ms* from `POST /vms` to the first command answered (HQ Vera, server long-poll
client): API ≈ 5 ms, runner ≈ 60 ms (Firecracker spawn 39–53 ms is the largest piece, snapshot load 4–6 ms), event back to
the client ≈ 2 ms, first command through the proxy ≈ 21 ms. The benchmark harness reports ≈ 275 ms for the same thing,
because its SDK polls for `running` (first poll after 250 ms).

*Under a 1,000-sandbox burst the time is spent waiting, not working.* With the fixes on, the typical sandbox
spends 0.3–0.9 s waiting for a runner slot (step B), 0.25–0.7 s in the runner clone (D) and 0.2–0.35 s for the
harness to notice it is running (E). The API itself takes ≈ 0.1 s of a burst sandbox's time.
],
[
*The dominant step differs per host* (1k burst, idle image, fixes on, p50):
- *HQ Vera:* queue for a runner slot 715 ms (256 in-flight cap), Firecracker spawn #red[208 ms] — 2.5× the other hosts.
- *EPYC 9575F:* API answering the POST 652 ms (all 1,000 accepted at once on 128 threads); clone 413 ms.
- *Graviton5:* the fastest clone (246 ms) and total (0.89 s).
- *Turin:* snapshot load + resume #red[484 ms] vs 16–39 ms elsewhere — its single biggest step, unexplained so far.

*Without the fixes, the init-disk copy + fsync dominates the clone:* 1,293 ms on the 9575F, 567 ms on Graviton5,
352 ms on Vera → 11–38 ms with the fix. *With the agent image* every runner step is CPU-starved (Firecracker spawn
1.7–1.8 s on Vera and the 9575F); Turin's clone stays at 1.2 s.
]
)

= The steps

#table(columns: (0.35fr, 1.1fr, 3.2fr, 1.6fr),
  [Step], [Component], [What happens], [Where it is measured],
  [A], [client → API], [`POST /vms`: TCP accept, auth, audit row, validation and DB lookups, `BEGIN`, insert `vms` + `jobs` rows, publish the create job to JetStream (waits for the store ack), `COMMIT`, HTTP 200], [client: POST sent → answered],
  [B], [API → JetStream → runner], [Job waits in the JetStream `JOBS` consumer until the runner has a free slot (`MaxAckPending` = 256 in flight by default; 2,048 on the 9575F), then the runner handler starts (semaphore 512)], [client send time → runner `boot-phases create` log line],
  [C], [runner], [Admission / capacity reserve, image resolve, manifest + template lookup], [runner journal],
  [D1], [runner], [Take a pre-built network namespace from the pool], [`netns_get_ms`],
  [D2], [runner], [Copy the scratch file and a private 16 MiB init disk, `fsync` it (#3260; `template.go`, `vm.go`)], [`scratch_cp_ms`],
  [D3], [runner + kernel], [Fork `rlp-fcns` (setns, join cgroup), exec Firecracker, wait for its API socket (#3212: 30 s wait)], [`fc_start_ms`],
  [D4], [Firecracker], [Load the template snapshot (memory file mapped, device state) and resume the vCPU], [`load_ms`],
  [D5], [runner → guest], [TCP-probe the guest daemon on :2280 until it accepts (the arm64 580 ms ARP stall lives here, #3265)], [`toolbox_wait_ms`],
  [D6], [runner + kernel], [Everything else in the clone: per-VM cgroup `mkdir` (#3261), register the instance, entrypoint trigger], [clone total − D1…D5],
  [E], [runner → NATS → API → client], [`running` event published, API overlay updated, client learns the state. Long-poll client: 2–3 ms. Harness SDK: polls at 0.25 s ×1.5 up to 2 s, so this step is mostly poll interval], [`running-emit` → client sees `running`],
  [F], [client → proxy → guest], [First command (`echo ready`) through the toolbox proxy to the guest daemon], [client],
)

#note[
*Method (sections 4–6).* Every host runs client, API, NATS, runner and guests on one machine, so all timestamps share one clock.
Each sandbox in the harness runs (`mpfleet.py`, 16 client processes) was joined by `vm_id` with the runner's journal
(`boot-phases create`, `boot-phases`, `running-emit` lines, pulled read-only from each host for the exact run windows).
Values are pooled over all reps, ms, *p50 / p90*. *† Step A overlaps step B*: the job is published before the API commits
and answers, so on the 9575F the runner often starts before the client gets its 200. Steps B, C, D, E, F are sequential;
medians of steps do not add up exactly to the median total. Turin has fixes-on data only (its fixes-off runner journal rotated
out); Turin used a 512-connection client pool and 64 MiB disks, the others 1,024 and 1 GiB.
]

#pagebreak()
= One sandbox at a time (low load)

== HQ Vera, server long-poll client, all sources joined (API audit + DB, NATS tap, runner journal)

#table(columns: (3fr, 1fr, 1fr, 1fr),
  [Step (ms)], [p50], [p90], [with all 4 fixes: p50 / p90 / p99],
  [1 client → API (HTTP, auth, audit)], [1.2], [1.3], [],
  [2 API handler before the DB transaction], [2.4], [2.7], [],
  [3 API DB insert + JetStream publish], [1.1], [1.4], [],
  [4 API commit + HTTP response], [0.6], [0.8], [],
  [5 queue: JetStream → runner handler], [0], [0.3], [],
  [6–8 runner admission, image resolve, manifest + template lookup], [1], [1], [],
  [9a network namespace from pool], [0], [0], [],
  [9b scratch copy + 16 MiB init-disk copy + fsync], [7], [8], [],
  [9c Firecracker spawn (incl. cgroup join) + API socket], [*39*], [45], [],
  [9d snapshot load + resume], [6], [7], [],
  [9e guest toolbox port accepts], [2], [#red[580]], [max 2 ms (stall gone, #3265)],
  [9f other: cgroup mkdir, register, entrypoint trigger], [3], [4], [],
  [10 running event → NATS], [0.9], [1.3], [],
  [11 API sees running → long-poll answers client], [1.2], [1.6], [],
  [*POST → client sees `running`*], [*65*], [*644*], [*64 / 69 / 73*],
  [12 first exec through the proxy (`echo ready`)], [21], [26], [],
  [*POST → first exec done*], [*88*], [*662*], [≈ 85],
)
#text(8.3pt)[200 sequential creates (control) and 60 sequential creates per fix arm. 23 % of control creates stall ≈ 580 ms in step 9e
(lost first ARP after resume on arm64); a permanent neighbour entry removes it. Source: `CREATE-PATH-STEPS.md`.]

== Harness client, 10 sandboxes at once (warm-up runs), all hosts with runner data

#twarm
#text(8.3pt)[The harness total is ≈ 275 ms on every host, fixes or not: step E (≈ 180–220 ms) is the SDK's first status poll at
250 ms, not platform time. The runner clone is 48–68 ms with the fixes (Vera's Firecracker spawn is the slowest piece, 53 ms).]

#pagebreak()
= 1,000 sandboxes at once — idle image (`alpine:3.20`)

#t1kidle

*Reading.*
- *Fixes off:* D2 (init disk + fsync) is the largest runner step on every host — 1.3 s on the 9575F, 0.57 s on Graviton5,
  0.35 s on Vera. Vera additionally spends 1.27 s queued for a runner slot (B).
- *Fixes on:* D2 drops to 10–38 ms. What remains: the queue (B: 0.3–0.9 s), Firecracker spawn (D3: Vera 208 ms, others
  26–83 ms), cgroup/register (D6: 17–155 ms) and, on Turin only, snapshot load (D4: 484 ms).
- The API share (A) is 0.2–0.3 s except on the 9575F (0.65 s), where all 1,000 POSTs are accepted at once and compete for
  128 threads; that does not delay the runner, which already has the jobs (B = 0.41 s).

#pagebreak()
== HQ Vera deep trace, 1,000-sandbox burst (long-poll client) — which fix moves which step

#table(columns: (2.6fr, 1fr, 1fr, 1fr, 1fr, 1fr),
  [Step (ms, p50 / p90)], [control], [+init-disk nofsync], [+cgroup pool], [+API backlog], [*all four*],
  [1 client → API], [40 / 1,072], [41 / 1,066], [49 / 1,077], [34 / 51], [*32 / 61*],
  [2 API handler before DB txn], [18 / 80], [13 / 22], [30 / 35], [87 / 451], [45 / 72],
  [3+4 API DB insert, publish, commit, response], [10 / 35], [13 / 39], [24 / 37], [14 / 122], [13 / 55],
  [5 queue → runner handler], [793 / 1,247], [337 / 822], [629 / 964], [1,214 / 2,180], [*421 / 1,172*],
  [9b scratch + init-disk copy], [300 / 700], [*9 / 20*], [516 / 689], [126 / 959], [*11 / 35*],
  [9c Firecracker spawn + API socket], [63 / 180], [106 / 219], [60 / 137], [56 / 144], [200 / 289],
  [9d snapshot load + resume], [12 / 69], [39 / 148], [11 / 39], [94 / 381], [20 / 58],
  [9e guest toolbox accepts], [3 / 11], [4 / 478], [3 / 14], [4 / 462], [5 / 76],
  [9f cgroup mkdir, register, trigger], [201 / 381], [427 / 565], [*24 / 58*], [123 / 495], [139 / 269],
  [11 API → long-poll answers client], [3 / 89], [2 / 4], [61 / 250], [2 / 65], [1 / 4],
  [*POST → client sees running*], [*1,927 / 3,035*], [1,600 / 2,709], [1,725 / 2,653], [2,296 / 3,370], [*1,054 / 1,748*],
  [listen-queue overflows per burst], [424–687], [460], [656], [0], [0],
)
#text(8.3pt)[Each fix alone moves 10–20 %; together −45 %. Removing one bottleneck hands the time to the next (the backlog fix alone is
slightly worse end-to-end: requests stop waiting on TCP retries and wait in the runner queue instead).]

#pagebreak()
= 1,000 sandboxes at once — agent image (startup under CPU load)

#t1kagent

*Reading.* Every sandbox starts a ≈ 3–4 core-second job at boot, so the runner competes with the guests for CPU. Firecracker
spawn (D3) and cgroup/register (D6) balloon to seconds on Vera and the 9575F; queue waits (B) reach 2–4 s on Vera. Turin
(384 threads, fast cores) keeps the whole clone at ≈ 1.2 s and the total at 2.6 s; its D4 snapshot load (0.87 s) is again
the largest piece. The fixes do not help here: faster early steps only start the guests' jobs sooner.

= 2,000 sandboxes at once (fixes on)

#t2k

*Reading.* At 2,000 the queue for a runner slot (B) becomes the largest step everywhere: 0.9–2.3 s idle, 4–16 s with the
agent image. The 9575F (in-flight cap 2,048) has the shortest idle queue; Vera and Turin run the default 256.

#pagebreak()
= What to take from this

#table(columns: (1.3fr, 3fr),
  [Finding], [Detail],
  [The platform's own work is small], [≈ 60 ms of runner work and ≈ 5 ms of API per sandbox when idle; under a burst the API share is ≈ 0.1 s (long-poll client) and the rest is queueing behind serialized kernel work and the 256-slot cap.],
  [The harness adds a fixed ≈ 0.2–0.35 s], [Step E is SDK polling (0.25 s ×1.5 up to 2 s); the long-poll client sees `running` in 1–3 ms. Compare hosts with the same client, and use long-poll for absolute numbers.],
  [Vera's slow step: Firecracker spawn], [208 ms p50 in a burst (53 ms idle) vs 26–83 ms on the other hosts. Includes forking `rlp-fcns`, joining the cgroup and waiting for the API socket. Worth a per-step trace on Vera (fork/exec, cgroup join, page-table setup on 64 KiB pages).],
  [Turin's slow step: snapshot load], [484 ms p50 idle burst (0.87 s agent) vs 16–39 ms elsewhere on the same build. Not yet explained; candidates: snapshot memory file read path on the single NVMe / page cache, Firecracker's x86 restore cost at this concurrency.],
  [Queue cap differs across hosts], [`RLP_VM_MAXACK` 2,048 on the 9575F vs 256 on Vera, Turin and Graviton5. It sets step B; equalize before comparing burst startup across hosts.],
  [Agent-image numbers measure CPU], [All runner steps stretch with guest CPU load; Turin's lead there is CPU throughput, not a faster create path.],
)

#v(0.3em)
#text(8.3pt, fill: gray)[Data: per-run client JSONL from `vera-hq-cell-20261014/{fixes-bench,epyc9575-fixes-bench,run2k-*}.tgz`,
`graviton5-cell-20261014/fixes-bench.tgz` (first attempt's ON arm excluded: only the API flag applied), `phoenix-e6-cell-20261014/results-fixed.tgz`;
runner journals pulled read-only for the exact run windows (`create-path-breakdown/runner-journals.tgz`); join and statistics in
`create-path-breakdown/analyze.py` → `agg.json`, `agg-warm.json`; tables generated by `gen_tables.py`. Deep Vera trace: `vera-hq-cell-20261014/CREATE-PATH-STEPS.md`.]

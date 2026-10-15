# Session summary — Vera vs EPYC benchmark investigation (2026-10-13 / 14)

Durable record of this session. Everything lives in this folder:

| file | contents |
|---|---|
| `SESSION-SUMMARY.md` | this file: conclusions, GitHub trail, machine state, next steps |
| **`BASELINE-VERA-FIXES-20261014.md` / `.json`** | **reference results for comparison: fixes OFF vs ON (harness + per-step)** |
| **`BASELINE-EPYC9575-FIXES-20261014.md` / `.json`** | **9575F on the same build, fixes OFF vs ON, the Vera vs 9575F comparison, and the 2,000-sandbox runs** |
| `run2k-epyc9575.tgz`, `run2k-vera.tgz` | 2,000-sandbox startup + level-2000 ladder, both hosts |
| **`power-mem-20261015/RESULTS.md`** | **jobs per watt + memory bandwidth, both hosts (+ raw data, Vera meter analysis, ACPI tables)** |
| `FINDINGS.md` | running findings log, chronological |
| `CREATE-PATH-STEPS.md` | per-step create-path measurements on HQ Vera, root causes, **corrected results with the four fixes** |
| `NOTE-TO-DANIEL.md` | draft briefing for Daniel (not sent) |
| `patches/` | `runner-fixes.diff`, `api-backlog.diff` (the four fixes); `bench-build/` = exact build on the cell |
| `posted/` | text of every issue and comment posted to GitHub |
| `scripts/`, `scripts/create-path/` | every script used (harness, natstap, stepclient, analyzers, bpftrace, A/B drivers) |
| `bench-results.tgz`, `bench-results-2.tgz` | HQ Vera runs, morning and early afternoon |
| `epyc9575-entry-ab.tgz` | 9575F idle-image vs agent-image A/B |
| `create-path-steps.tgz` | create-path per-sandbox data, pcap, bpftrace outputs |
| `arp-and-api.tgz` | ARP-stall traces, neighbour A/B, API pool A/B |
| `patched-arms.tgz` | the 14 measurement arms with the patched build |
| `fixes-bench.tgz`, `fixes-bench-log.txt` | harness startup + throughput benchmarks, fixes off vs on |
| `cell-config/` | HQ Vera cell config, secrets redacted |

Methodology for future runs: `docs/benchmark-methodology.md` in the harness (PR danielgraviet/arm64-benchmark-1#1).

## Headline conclusions (final, supersede earlier drafts)

1. **"Startup" has been measured under the image's own CPU load.** The benchmark image's entrypoint
   (`workload.agent --n 30`) runs in every sandbox at boot (~3 core-s each). With an idle image (`alpine:3.20`),
   **HQ Vera and the EPYC 9575F both bring up 1,000 sandboxes in ~4 s** (p95 3.8–4.2 s), using ≤ 40 cores.
   With the agent image: Vera one socket ~10 s, 9575F 24–31 s. That gap is CPU throughput on the entrypoint workload.
2. **Throughput:** HQ Vera 26.6 jobs/s with both sockets, 13.0–14.0 on one socket (published 13.3 = one socket). 9575F
   ~8 and 9755 ~11 (published, single socket). Platform overhead 0.5–0.6% per job; the plateau is cores × per-core rate
   under load (9575F loses 24% clock when packed).
3. **NUMA pinning is not a startup lever.** It only matters while guests run CPU work (agent image: 10 s pinned vs 22 s
   unpinned; alpine: identical). My earlier "2.3× NUMA lever" claim was wrong; corrected on daytona/rlp#391.
4. **`post_s` ("control plane accepts the request") is client queueing** with a single-process client, and with
   fresh connections it also includes ~1 s TCP retries from the API's 128-entry accept queue (#3269).
5. **9575F published startup numbers were inflated** by `rlp-cpu-weight-floor.sh` (stopped; cmdline in
   `/root/floor-cmdline.txt`), and several published means drop/keep outliers selectively.

## The create path, step by step (HQ Vera) — see `CREATE-PATH-STEPS.md`

6. **Unloaded, a sandbox is usable in ~88 ms**: API ~5 ms, runner ~59 ms (Firecracker spawn 39 ms), first exec 21 ms.
7. **~25% of unloaded creates stalled a fixed ~580 ms** (p99 658 ms). Root cause (#3265): the host's first ARP for the
   guest is lost during restore (53/60 pool netns hold a `FAILED` entry), the daemon's resume announcement never fires
   on arm64 (the guest's monotonic clock resumes at the snapshot instant), and the 1 s keepalive's frozen phase decides
   the wait. Side finding: the guest wall clock is 2 h 52 min behind (template age; #767).
8. **A 1k idle-image burst took ~1.9–2.1 s per sandbox (p50)**, going to: the queue for 256 runner slots (~0.8–1.2 s),
   a 16 MiB init-disk copy + fsync per clone (~300 ms; NVMe pinned at 97%, #3260), serialized cgroup creation
   (~200 ms; ~0.9 s per 1,000 on 352 CPUs, memory controller, #3261), and the API's 128-entry accept queue
   (~550 overflows per burst, ~1 s TCP retries, #3269). The API's DB pool is **not** a bottleneck (≤16 of 64 used).
9. **Ruled out for the burst:** Go fork serialization, cgroup2 `favordynmods`, `RLP_VM_MAXACK`, `halt_poll_ns`.

## Corrected results with the four fixes (patched build, same binary, flags off = control)

| | before | after (all four fixes) |
|---|---|---|
| unloaded POST → running, p50 / p99 | 67 / **658** ms | 64 / **73** ms |
| unloaded clones stalled | 4–16 of 60 | **0 of 60** |
| 1k burst POST → running, p50 / p90 | **1927 / 3035** ms | **1054 / 1748** ms (−45%) |
| 1k burst listen overflows | 424–687 | **0** |

- Per fix: init disk `nofsync` 300 → 9 ms; cgroup pool (warm from runner start) 201 → 24 ms; permanent neighbour
  stalls 4/60 → 0/60; backlog 4096 overflows → 0.
- **The fixes only pay off together.** Alone each moves 10–20%; the backlog fix alone is slightly *worse* end-to-end
  (requests stop waiting on TCP retries and wait for a runner slot instead).
- **The cgroup pool must be warm before the burst.** Filled lazily on first use, 9f stayed at 454 ms.
- **Next bottlenecks:** queue for a runner slot (421 ms; 256 `MaxAckPending` cap) and Firecracker spawn (200 ms).

**Harness benchmarks with the fixes (published method):** idle-image 1k startup p50 2.3 → **1.6 s**, p95 3.5 →
**2.6 s** (−30%); agent-image startup and the throughput ladder (26.7 jobs/s at 352) **unchanged**. Tails are now
held by guests wedging after resume (1-vCPU oopses, #3213 family), at the same rate with fixes on or off.

**9575F on the same build, fixes OFF vs ON:** idle-image 1k startup create p50 2.51 → **1.06 s** (−57%), p95
3.68 → **1.59 s**; agent startup ~15% faster; throughput unchanged (8.0 jobs/s). **With the fixes on, the 9575F
starts sandboxes faster than Vera** (p50 1.06 vs 1.57 s, p95 1.59 vs 2.57 s); Vera keeps a ~3.3× throughput lead
(26.7 vs 8.0 jobs/s). No wedged guests on the 9575F.

**At 2,000 sandboxes (fixes ON):** both hosts run 2,000 at once with ≤1 failure per 16,000 jobs; ~180 MiB per
sandbox under the agent workload, so memory is not the limit up to the 3,000 cap. Throughput stays 8.0 (9575F) vs
26.1 (Vera) jobs/s. Idle startup p50 2.4 vs 2.9 s (9575F ahead); agent-image all-ready 58–71 vs 50–55 s (Vera ahead).

**Jobs per watt / memory (2026-10-15):** processor-level Vera 23.7 vs 9575F 21.1 jobs/s per kW (scopes differ;
Vera ~29-32 in an AMD-like scope); both CPUs at their power limits at the plateau; memory triad plateau Vera ~2.1 TB/s
vs 9575F ~0.30 TB/s. Vera has no wall-power sensor. See `power-mem-20261015/RESULTS.md`.

## Ruled out (whole session)
Proxy capacity · event auditing · API restarts · cpuidle/init_on_alloc · client pool/polling/disk · SMT FC fork for
1-vCPU · memory bandwidth · second socket for the control plane · `RLP_VM_MAXACK` 256→1024 · KVM `halt_poll_ns` 0 ·
`RLP_MIGRATABLE` for #3213 · Go fork serialization · cgroup2 `favordynmods` · API DB pool size.

## GitHub trail (texts in `posted/`)
- **daytona/rlp#3212** 3 s FC socket wait (A/B posted).
- **daytona/rlp#3213** 2-vCPU clone oops: RLP_MIGRATABLE A/B (no effect) + snapshot-timing hypothesis.
- **daytona/rlp#391** NUMA placement: pin A/B posted, then **corrected** (entrypoint, not NUMA).
- **daytona/rlp#3229** readiness gate is a bare TCP accept; hung-exec guests look healthy.
- **daytona/rlp#3260** init-disk copy + fsync — filed, then A/B posted (300 → 9 ms).
- **daytona/rlp#3261** cgroup creation — filed, then A/B posted (201 → 24 ms; warm-pool and adoption caveats).
- **daytona/rlp#3265** ~25% of arm64 clones stall 580 ms — filed with root cause, then A/B posted (0/60).
- **daytona/rlp#3269** API accept backlog 128 — filed, then A/B posted (overflows → 0).
- **daytona/rlp#767** comment: arm64 guest wall clock = template age behind; monotonic clock does not jump.
- **danielgraviet/arm64-benchmark-1#1** methodology doc, AGENTS.md section, bench-preflight.sh, mpfleet.py
  (3 commits; open, not merged).

No fix is merged upstream; the patches are measurement builds.

## Host / config incidents
- RedSwitches hosts lacked their hostname in `/etc/hosts` → sudo blocked on DNS (fixed).
- HQ Vera shipped E2B prep (1.44 TB hugepages, nbd×4096); unfiltered iscsi udev rule + libvirtd + fwupd.
- systemd `EnvironmentFile=` beats `Environment=`; `/etc/rlp` is root-only, so unprivileged `[ -s ]` checks
  silently fail (cost one A/B arm).
- `mount -o remount` cannot switch cgroup2 `favordynmods` off; use `--options-source=disable` with the full list.
- The runner sizes its disk capacity from the scratch filesystem: a 96 GB tmpfs admitted only ~95 sandboxes.
- After a runner restart the netns count is briefly high (stale slots), then dips and refills: wait for two
  consecutive high samples before a burst.
- 9575F `/etc/rlp/bench-api-key` is **stale** (401); the harness `.env` key works.
- Concurrent operator (Daniel's Codex) on HQ Vera 01:06–05:57 UTC Oct 14; his changes saved in
  `/etc/rlp/daniel-backup-20261014_063749/`. I briefly overwrote his newer AGENTS.md on Vera; restored.
- Vera harness checkout has unpushed local commits up to `9fe41bc`.
- 1,460 orphaned init-disk copies (23 GB) in `/mnt/data/rlp/scratch` from the 01:34 UTC window (left in place).
- Leftover from my pinning experiments: `cpuset` enabled in `rlp.slice/vms/cgroup.subtree_control` (harmless for
  cost, measured; left in place).

## Machines at end of session
| host | access | state |
|---|---|---|
| HQ Vera `10.96.8.228` | reverse tunnel (`tmux rtun` on Vera → `ssh -p 2228 daytona@localhost` here) | idle, 0 sandboxes, unpinned, original cgroup mount, no drop-ins. **Runs the patched binaries with the four fixes ON** (drop-ins `20-create-path-fixes.conf` → `/etc/rlp/create-path-fixes-{runner,api}.env`; runner `0fd55bab4ad6`, api `1648ab971fe5`); stock binaries at `*.bak-prepatch`. Preflight prints `create_path_fixes ON`. Rust 1.99 installed for the daytona user. Patched runner source in `~/rlp-src/runner`. All changes in `/etc/rlp/HOSTCHANGES` |
| EPYC 9575F `<epyc9575-host>` | `ssh root@` | idle, 0 sandboxes. **Runs the same bench build as Vera with the fixes ON** (runner `739fc73a116d`, api `93fa5e93bf20`; drop-ins `15-bench-common.conf` = `RLP_FC_SOCK_WAIT_MS=30000`, `20-create-path-fixes.conf`); old stock binaries at `/usr/local/bin/rlp-{runner,api}.bak-prepatch`. Rust installed for root; source in `/root/rlp-bench-src`. Harness has the read-timeout knob (backup `.bak-readto`). Floor script stopped |
| EPYC 9755, Zenlayer | host keys changed — not accepted | — |
| OCI Vera | Daniel only | — |

The fixes are ON at HQ Vera. To turn them off: `sudo rm /etc/systemd/system/rlp-{runner,api}.service.d/20-create-path-fixes.conf`,
`daemon-reload`, restart `rlp-api` then `rlp-runner`.

## Open next steps
1. Decide whether to turn the four patches into PRs (project-tracking + PR pipeline apply). The cgroup pool needs the
   adoption question answered first; #3265 also needs the daemon's resume detector fixed for non-pool paths.
2. Commit the harness read-timeout knob (`RLP_HTTP_READ_TIMEOUT_S`) to the harness PR; add the 1-vCPU oops
   evidence to #3213.
3. Next burst bottlenecks: the 256 in-flight `MaxAckPending` cap and Firecracker spawn under concurrency.
3. #3213: settle-before-pause runner patch; per-template variance; 4 KiB host kernel.
4. Re-run the published startup comparison with an idle image on every platform (9755 needs access).
5. Daniel: merge PR #1, push the Vera local commits, relabel `post_s`, rerun startup with alpine (send NOTE-TO-DANIEL.md).
6. Rotate the BM1/BM2 root passwords pasted earlier.

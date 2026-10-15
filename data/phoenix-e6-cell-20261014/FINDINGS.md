# phoenix-e6 bench cell — configuration and first results

**Host:** OCI Phoenix `BM.DenseIO.E6.Ax.192`, `<turin-host>` (private `10.6.2.170`), login `ubuntu`,
hostname `vedran-test`. Built 2026-10-14.

**Why this cell exists:** a like-for-like rerun of the HQ Vera benchmark on AMD EPYC 9J45 (Turin),
using the same Daytona build, the same client and the same recipe, so the Vera numbers have an
x86 comparison that is not confounded by software differences.

## Hardware

| | |
|---|---|
| CPU | AMD EPYC 9J45 (Turin), 2 sockets x 96 cores, SMT2 → 384 threads, boost 4.12 GHz, governor `performance` |
| NUMA | node0 = 0-95,192-287 · node1 = 96-191,288-383 · L3 1 GiB (32 instances) |
| Memory | 2,267 GiB |
| Disk | 12 x 6.8 TB Solidigm NVMe. **Only `nvme0n1` is used** (ext4, `/mnt/data`, 6.9 TB) |
| Kernel | `6.17.0-1020-oracle`, page size **4 KiB** |
| Network | 2 x 200 Gbit (`enp19s0`) |

### Storage deviates from the OCI default, deliberately

Cloud-init had assembled all 12 NVMe into a RAID10 (`md127`, 42 TB xfs) that was **1.7 % into a
60-hour initial resync** — every snapshot restore would have competed with it. HQ Vera, the host
being matched, has **no RAID**: one NVMe carries root and `/mnt/data/rlp`. The array was empty, so
it was stopped and the superblocks zeroed; `/mnt/data` is now plain ext4 on `nvme0n1`.
`nvme1n1`..`nvme11n1` are unused and free for a RAID0 A/B later.

## Software — identical to the HQ Vera cell

| | |
|---|---|
| Daytona | `f0611fa13` + cherry-pick `6883d3366` (EROFS `-b 4096`) + the `RLP_FC_SOCK_WAIT_MS` knob + `8d2b090ff` `RLP_FC_SMT` (inactive), built x86_64 on the box |
| Firecracker | stock v1.16.1, sha `2fd0171309af…` (the sha pinned in `deploy/bin/SHA256SUMS`) |
| Guest kernel | `vmlinux-6.8.12-rlp3`, copied from the 9575F cell |
| In-guest daemon | `rlp-rs-0.4.1` layer, copied from the 9575F cell — the daemon every AMD cell runs |
| Client | Daniel's harness + the eng `rlp` SDK, copied from the 9575F cell |
| Backing services | Postgres 16 and NATS 2.10 in host-network containers, `synchronous_commit=off` |

Binary shas: `rlp-api d5f5…`/`84a383bcceb7`, `rlp-runner d5f501e813a0`, `rlp-proxy f7a0da7a419f`,
`firecracker 2fd0171309af`. Full config: `/etc/rlp/{BUILD,api.env,runner.env,proxy.env,regions.json}`,
host changes: `/etc/rlp/HOSTCHANGES`.

Cell identity: region `phoenix-e6`, runner `phoenix-e6-1`, cpu type `turin-9j45`, harness target
`phoenix-e6`.

### Host posture (every gate from `docs/benchmark-methodology.md`)

ARP `gc_thresh3` 65536 (v4+v6), conntrack 1M, `nr_hugepages=0`, `nofile` 1,048,576,
`numa_balancing=0` (HQ Vera boots `numa_balancing=disable`), the unfiltered open-iscsi udev rule
shadowed for `rlp*|veth*|tap*|fc*`, `libvirtd`/`fwupd` stopped and runtime-masked, hostname pinned
in `/etc/hosts`. `bench-preflight` is installed at `/usr/local/bin/bench-preflight` and gates every
rep.

## Results — 1,000 and 2,000 sandboxes create-ready

Recipe: `dtgraviet/vera-agent-benchmark:v3`, cpu 0.025 / mem 64 MiB / disk 1 GiB, warm snapshot
clones, probe `echo ready`. `ready_wall_s` = burst start → last sandbox ready **and probed**.

### 1,000, one client process (directly comparable to the HQ Vera pin-ab runs)

| arm | rep1 | rep2 | rep3 | failures | fc-socket timeouts | self-cordons |
|---|---:|---:|---:|---:|---:|---:|
| socket 0 only (96c/192t) | 10.22 s | 10.77 s | 10.80 s | 0 | 0 | 0 |
| whole box (192c/384t) | 11.21 s | 10.61 s | 10.92 s | 0 | 0 | 0 |

### 1,000 and 2,000, 16 client processes (`mpfleet.py`, the methodology's burst client)

| arm | n=1,000 | n=2,000 | failures |
|---|---|---|---:|
| whole box (192c/384t) | **7.90 / 8.01 / 7.97 s** | **22.30 / 21.94 s** | 0 |
| socket 0 only (96c/192t) | 12.52 / 11.89 / 11.87 s | 29.55 / 30.97 s | 0 |

Every rep above landed all 1,000 / 2,000 sandboxes ready and probed, with zero fc-socket timeouts
and zero self-cordons.

Runner-side per-clone time at low load: `template=hit total_ms≈84–108`
(`scratch_cp≈42 ms`, `fc_start≈12 ms`, `load≈5 ms`, `toolbox_wait≈17 ms`).

## What these results say so far

1. **The box matches HQ Vera on startup.** 1,000 ready in **7.9 s** whole-box / **10.2 s** on one
   socket, against HQ Vera's 8.4–10.6 s pinned to one socket. 2,000 in **21.9-22.3 s** against Vera's
   27.4 s (the published HQ figure). No failures, no fc-socket timeouts, no self-cordons in any run.
2. **Vera's NUMA penalty does not reproduce here.** On Vera, spreading across both sockets cost
   2.3x (8.4–10.6 s → 20–23 s). On this EPYC, unpinned is within noise of pinned with the
   single-process client (10.6–11.2 vs 10.2–10.8 s), and with 16 client processes the whole box is
   **faster** than one socket at both sizes (1k: 7.9-8.0 vs 11.9-12.5 s; 2k: 21.9-22.3 vs
   29.6-31.0 s) - once the client is no longer the bottleneck, the second socket helps instead of
   hurting. Pinning on this box mostly starves the client.
3. **The single-process client is again the limiter at 1k.** Same host, same runs: 1 process
   10.2–10.8 s with `accept_p50` 4.6–4.8 s; 16 processes 7.9 s with `post_p50` 0.22 s. This
   reconfirms the HQ Vera finding that `post_s` from a one-process client is harness queueing, not
   control-plane time.
4. **Deliberate deviation to be aware of when comparing to other OCI boxes:** this cell runs on one
   NVMe, not the 12-disk RAID10 the OCI image builds.

## Open / next

- A density ladder beyond 2,000 (`RLP_MAX_LIVE_VMS=3000`, `RLP_NETNS_POOL=2100`
  currently cap it; the box has 2.2 TB of memory and 192 cores, so it should go far higher).
- The agent-throughput ladder (jobs/s plateau), which is the other published number.
- `RLP_VM_MAXACK` A/B: this cell runs the stock 256 in-flight create cap, like HQ Vera. The 9575F
  runs 2048.
- RAID0 across all 12 NVMe as a storage A/B, if the single-drive restore path ever shows up as the
  limit.
## Concurrency ceiling — 2026-10-14

**Result: 8,000 concurrent sandboxes, and nothing in the hardware stopped us.** Every ceiling hit
was a configured limit; the box was at 21 % of memory, 55 % of its CPU reservation budget and 7 %
of its scratch budget when the last one tripped.

Method: `mpfleet.py --procs 16` against `alpine:3.20` (idle entrypoint — per §0 of the methodology,
the agent image would have measured CPU throughput instead), in waves that are kept alive, each
wave probed with `echo ready`. Run dirs: `/mnt/data/bench/{ladder,waves}-*`.

### The ladder

| what was run | result | what actually stopped it |
|---|---|---|
| single burst, 1,000 | 7.95 / 7.96 s, 0 failed | — |
| single burst, 2,000 | 23.2 s, 0 failed | — |
| single burst, 3,000 | 42.7 s, 0 failed | — |
| single burst, 4,000 | 81.9 s, 0 failed | — |
| single burst, 5,000 | 3,941 of 5,000 | **60 s create-pickup cap.** 962 of the failures are `create job not picked up by any runner within 60s`. `CREATE_MAX_QUEUE_SECS_CAP` is a hard-clamped constant (`api/src/events/mod.rs:437`); `RLP_CREATE_MAX_QUEUE_SECS` cannot raise it |
| waves of 1,000, 1 GiB scratch | **6,742** held | **scratch reservation.** Runner gate: `reserved ScratchMiB 6,903,808` vs `95 % × 7,266,782`. 6,903,443 ÷ 1,024 = 6,741. Reproduced to ±1 across four runs, with the cap raised to 900 s and `RLP_MAX_LIVE_VMS` at 8,000 and 20,000 |
| waves of 2,000, 64 MiB scratch | **8,000** held | **API overload shed.** `RLP_MAX_QUEUED_CREATES` (default 8000, `api/src/state.rs:429`) → `429 create queue at capacity`, rejecting all 2,000 of wave 5 in 0.3 s |

Wave timings at 64 MiB scratch were flat all the way up: 2,000 sandboxes ready in 10.5 s, 10.3 s,
12.3 s, 12.7 s for waves 1–4 (i.e. the 7,999th sandbox starts as fast as the first).

### Headroom at 8,000 live

| resource | used | budget |
|---|---|---|
| memory | 406 GiB (`MemAvailable` 2,200 → 1,794 GiB) | 2,267 GiB |
| runner CPU reservation | 200 of 364.8 (0.025 × 8,000) | 95 % × 384 |
| scratch reservation | 500 GiB (64 MiB × 8,000) | 95 % × 6.9 TB |
| netns | 8,000 of 14,200 created | pool auto-grows |
| guest IPs | 8,000 | /18 = 16,382 |

Extrapolating the first binding *hardware* constraint: CPU reservation at 0.025/sandbox runs out at
**14,592**, memory at 64 MiB/sandbox at ~34,000.

### Three things worth knowing before the next density run

1. **Scratch is reserved, not used.** At 6,742 sandboxes the reservation was 6.9 TB while actual
   use was 110 GB (~16 MiB each). A 1 GiB `disk` in the recipe costs 64× its real footprint and is
   what caps a 7 TB host at 6.7k. Ask for what you use.
2. **The netns pool refill is the slowest thing on the box.** Growing it (2,100 → 6,200, then each
   +4,000 as the fleet consumes it) takes 15–20 minutes at load > 1,000, during which SSH barely
   responds and no benchmark is valid. Size it before a ladder, not during one, and let the
   preflight's `netns_pool_warm` gate hold you.
3. **Tearing down thousands of sandboxes is minutes, not seconds** (6,742 → 0 took ~7 min). Budget
   it between levels; a rep started on a dirty host fails the preflight for a reason.

### Cell changes made for this ladder (see `/etc/rlp/HOSTCHANGES`)

- `CREATE_MAX_QUEUE_SECS_CAP` 60 → 900 in the cell's own API build, plus
  `RLP_CREATE_MAX_QUEUE_SECS=600`. **Bench cell only** — the 60 s cap exists so a create with no
  capacity fails fast with a truthful error. Revert by rebuilding from a clean tree.
- `RLP_MAX_LIVE_VMS` 3000 → 20000, `RLP_NETNS_POOL` 2100 → 6200, `RLP_SUBNET_CIDR` /20 → /18
  (a /20 is 4,094 usable addresses and would itself have capped the host).
- `kernel.numa_balancing=0`, matching HQ Vera's boot line.
### Past 8,000: the ceiling is the runner's heartbeat, not the hardware

With `RLP_MAX_QUEUED_CREATES=40000` the shed gate stops binding and the ladder goes further:

| wave | cumulative live | wave wall | failures |
|---|---:|---:|---:|
| 1 | 2,000 | 10.3 s | 0 |
| 2 | 4,000 | 10.3 s | 0 |
| 3 | 6,000 | 12.3 s | 0 |
| 4 | 8,000 | 14.7 s | 0 |
| 5 | **9,750** | 224.7 s | 250 (`failed to start, reason=None`) |

**Peak: 9,750 concurrent sandboxes / 9,946 firecracker processes, with 1,696 GiB of memory still
free.** But the run ended in a control-plane failure, not a resource one:

```
20:26:53  wave4 complete — 8,000 live, 0 failures
20:27:38  rlp-api: "runner phoenix-e6-1 marked lost"
21:06:21  wave5 — 250 failures; vms: 9,876 lost / 124 running, while 9,946 firecrackers are alive
```

**What happened.** Under the load of ~8–10k guests (plus the netns pool growing by 4,000), the
runner's heartbeat starved past the reaper's threshold. The API marked the *runner* lost, and the
`lost_sweep` (`api/src/events/maintenance.rs:5199`) then marked every ephemeral VM on that runner
terminally `lost` — 9,876 of them, all of which were running and had answered `echo ready` moments
earlier. The runner returned to `online` on its own once the load dropped, but the rows stay
terminal, so the delete path can no longer reach those guests: **9,946 orphaned firecrackers that
only a `pkill` recovers.**

This is very likely the same mechanism behind the "runner crashed / `no matching capacity` /
thousands of leftover firecrackers" reports from the Phoenix, RedSwitches and Vultr boxes. It is a
density-induced liveness failure with a destructive cleanup, not a crash.

A second scaling limit sits next to it and is cosmetic by comparison: adoption verification is
capped at 4,096 VMs per host (`contract.AdoptionCheckMaxIDs`, whose comment reads "a host with 4096
adopted VMs is broken in a way this feature cannot help with"). Above that the runner logs
`adopt verify: adopted set exceeds the batch cap; skipping the check` and the check is permanently
inconclusive — it fails open, so it does not kill guests, but this host runs twice that routinely.

### So what is the ceiling?

| question | answer |
|---|---|
| comfortably, with clean bookkeeping | **8,000** — waves of 2,000 at 10–15 s each, zero failures |
| maximum observed alive | **9,750** (9,946 firecracker processes) |
| hardware limit | not reached — 1.7 TB memory free, CPU reservation 55 %, scratch 7 %, IPs 60 % |
| first hardware limit, extrapolated | CPU reservation at 0.025/sandbox → **14,592** |
| what actually stops it | the runner's heartbeat under its own load, followed by the lost-sweep |

To go higher the control plane has to survive the density: a heartbeat that does not starve behind
create work (or a reaper threshold that accounts for it), and a lost-sweep that does not terminally
reap a fleet whose guests are provably alive.

## Build provenance — which fixes the benchmarks actually ran with

Verified 2026-10-15 against `origin/main` 937f6596c.

| fix from the Vera/EPYC investigation | in these runs? | evidence |
|---|---|---|
| sudo storm (`1b2da010a`, PR #1754) | **yes** | an ancestor of `f0611fa13`; `RLP_PRIV_EXEC_CONCURRENCY` present in the running `rlp-runner`; runner at uid 0 (`User=root`), which is the condition the fix needs to exec `nft`/`ip` directly; **zero** `sudo nft`/`sudo ip` entries in the journal across the final ladder window |
| EROFS 4 KiB blocks (`6883d3366` / PR #1060) | **yes**, applied on top as `503878669` | not an ancestor of `f0611fa13`; carried as a cherry-pick in the build tree. Inert here — this host has 4 KiB pages |
| `RLP_FC_SOCK_WAIT_MS` (#3212 mitigation) | **yes**, local patch, set to 30000 | 0 fc-socket timeouts and 0 self-cordons in every run |
| `RLP_FC_SMT` (`8d2b090ff`) | present, **inactive** | arm64 SMT topology, not applicable on x86 |

**Deliberately not current.** The cell is pinned to `f0611fa13`, 264 commits behind `main`, which is
the same pin the HQ Vera and epyc9755 cells used — `main` moved `/vms` → `/sandboxes` and dropped
registry-image create, which this harness needs. That pin is what makes these numbers comparable to
the Vera and 9575F series; it also means they are not a statement about current `main`.

**Does the pin undercut the density finding?** No. As of `937f6596c` there is still no
`PingInterval`/`MaxPingsOutstanding` under `runner/`, `RUNNER_STALE_SECS` is still 30, and the
stale-mark and lost-sweep mechanisms are unchanged. The heartbeat path *was* refactored
(`publishHeartbeat`/`infoMu` exist only on `main`), but it does the same O(live_vms) work under the
same global VM mutex — two scans in the measured build, three to four on `main`. Recorded on #2459,
including a correction to the call path I first described there.

## All four create-path fixes applied — 1k and 2k, 2026-10-14

The fixes from `benchmark-fixes-findings-20261014.pdf` §1.1 were **not** in any earlier Turin run.
They are now: #3260/#3261/#3265 were taken from the HQ Vera bench tree (uncommitted; base
`d053f0317`, patch sha256 `5e2c25ee…`), and **#3269 was implemented here** — the API's listener is
tokio/mio's hard-coded `listen(fd,128)`, now bound explicitly via `TcpSocket` + `listen(backlog)`
behind `RLP_API_LISTEN_BACKLOG` (default 4096, `0` restores the old path).

Verified live before running: `Send-Q=4096` on `:8088` and the `listen backlog set backlog=4096`
log line; 2,408 pre-created pool cgroups; `10.255.0.2 … PERMANENT` neighbour entries in the pool
netns; `RLP_INITDISK_MODE=nofsync` in the runner's environment.
Build: runner `365db3e34b3a`, api `eba93b695d5a` (previous binaries kept as `*.bak-prefixes`).

### Results — same host, same 16-process client, fixes off → on

| run | fixes off | **fixes on** | change |
|---|---:|---:|---:|
| idle image, 1,000 | 7.95 / 7.96 s | **3.88 / 3.87 s** | **−51 %** |
| idle image, 2,000 | 23.22 s | **7.22 / 7.13 s** | **−69 %** |
| agent image, 1,000 | 7.90 / 8.01 / 7.97 s | 7.84 / 7.88 s | −1 % |
| agent image, 2,000 | 22.30 / 21.94 s | 21.41 s | −3 % |

Zero failures, zero fc-socket timeouts, zero self-cordons, and **zero TCP listen overflows** in
every run.

### This closes the PDF's open item on Turin

> *"Turin idle-image startup — ≈8 s per 1,000 vs ≈4 s on Vera and the 9575F; unexplained."*

Explained: the ≈8 s was measured **without these fixes**, against Vera/Graviton5 numbers taken
**with** them. With the same fixes on, Turin does 1,000 idle sandboxes in **3.88 s** — level with
Vera and the 9575F. There is no unexplained Turin startup deficit.

### Where the time went, and which fix earned it

Runner per-clone medians, idle 1k: `scratch_cp` **313 ms → 9 ms** (#3260 — the 16 MiB init-disk
fsync), with `load` now the dominant phase (507 ms p50). `toolbox_wait` stays 16–17 ms, and
`listen_overflows` was `+0` in every run — on this host **#3269 and #3265 fixed symptoms that were
not present**: Turin's accept path was already clean (`post_s` p50 0.23 s, no 1 s cluster) and its
toolbox wait never showed the arm64 ~580 ms ARP stall. The gain here is #3260 and #3261.

### The agent image barely moves, and that is the point

The agent image gains 1–3 % because its number is not startup — every sandbox runs a CPU-bound
entrypoint (methodology §0), so it measures the host's throughput on that workload. The fixes act
on the create path, which is a small share of it. The idle image is where create-path work is
visible, and there the same fixes halve 1k and cut 2k by more than two thirds.

### Caveat carried by #3261

`RLP_CGROUP_POOL` names per-VM cgroups from a pool, so a VM that outlives a runner restart cannot
be matched to its cgroup during adoption and usage falls back to `/proc`. The runner logs this as a
warning at startup. Acceptable on a benchmark cell; it is why the knob defaults to off.

## Throughput — dense agent ladder (the missing Turin row), 2026-10-15

Run with the identical method the other hosts used (`gapfill.sh HOSTP=phoenix PHASES=T
T_ARMS=UNPIN`): agent image, n=45, seed 42, `-E 8`, hold-then-exec, 0.025 CPU / max 1,
64 MiB / max 4 GiB, 16 MiB disk, unpinned, 2-second power + clock sampling. All four create-path
fixes on. Run dir `/mnt/data/bench/gapfill-phoenix-20261015_075448`.

| concurrency | 44 | 88 | 176 | 352 | 528 | 704 | 880 | 1,056 | 1,408 | 1,760 | 2,000 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **jobs/s** | 5.50 | 10.58 | 17.86 | 20.15 | **22.32** | 22.27 | 22.25 | 22.17 | 22.12 | 22.13 | 22.15 |
| job p50 (s) | 7.06 | 7.14 | 8.39 | 15.31 | 21.30 | 28.60 | 34.83 | 42.20 | 57.20 | 71.60 | 79.65 |

**0 failures at every level**, `checksum_ok: true` throughout, 16,000 jobs at the 2,000 rung.
The plateau is reached at 528 and is flat to 2,000 (22.32 → 22.15, −0.8 %).

### Derived — per-core and per-thread rate at the plateau

| Host | Plateau jobs/s | cores / threads | per core | per thread | clock drop packed | single job, light load |
|---|---:|---|---:|---:|---:|---:|
| HQ Vera | 26.7 | 176 / 352 | **0.152** | 0.076 | −6 % | 5.9 s |
| Graviton5 | 22.9 | 192 / 192 | 0.119 | **0.119** | −3 % | 6.65 s |
| **Turin (phoenix-e6)** | **22.2** | **192 / 384** | **0.116** | **0.058** | **−21 %** | **7.06 s** |
| EPYC 9575F | 8.0 | 64 / 128 | 0.126 | 0.063 | −24 % | 6.7 s |
| EPYC 9755 (published) | ≈ 11 | 128 / 256 | 0.086 | 0.043 | — | 7.1 s |

Turin clock, measured directly rather than from the whole-machine mean: **4.155 GHz** on a single
busy core at light load, **3.276 GHz** all-core during the packed rungs (n=647 samples) → −21 %.
Package power 595 W light → 977 W packed (RAPL).

### What this settles

The previous report called Turin's ladder "the decisive missing row", with the hypothesis that
Turin's 2.5–3× faster agent-image bursts might mean it matches or beats Vera on throughput.
**It does not.**

- **Vera keeps the throughput crown: 26.7 vs Turin's 22.2 jobs/s (+20 %).**
- Per *physical core* Vera is 31 % ahead (0.152 vs 0.116). Turin's second hardware thread adds
  little: at 192 cores / 384 threads it lands essentially level with Graviton5's 192 single-threaded
  cores (22.2 vs 22.9), and per thread it is the lowest of the four.
- Turin behaves like the other x86 part under load: −21 % clock when packed, close to the 9575F's
  −24 % and unlike Vera (−6 %) or Graviton5 (−3 %). That clock loss is most of the gap.
- Where Turin wins is **startup and density**, not throughput: 1,000 idle sandboxes in 3.88 s, 2,000
  in 7.1 s, and 8,000 live sandboxes held cleanly — see the sections above.

Turin also produced the cleanest ladder of any host measured: zero failures at all eleven rungs,
against one failure in 16,000 jobs on both Vera and the 9575F.

## Power baseline and jobs per watt, 2026-10-15

Idle baseline measured with the power-mem kit (`HOSTP=phoenix IDLE_ONLY=1 power-ladder.sh`,
180 s, 90 samples); the per-level power comes from the 2026-10-15 throughput ladder, whose sampler
recorded the same scope (sum of both RAPL packages — `gapfill-sampler.py` sums
`intel-rapl:[0-9]`, n=2). Analysed with the kit's own `power-report.py` after adapting the older
sampler file to its column layout. **AMD RAPL package power excludes DRAM**, and this OCI instance
exposes no BMC, so there is no wall-power figure.

**Idle: 178 W** (89.4 + 89.0 W across the two packages), host otherwise quiet, 0 sandboxes.

| level | jobs/s | processor W | jobs/s per kW | J per job | J per job above idle |
|---:|---:|---:|---:|---:|---:|
| 44 | 5.50 | 599 | 9.2 | 108.9 | 76.5 |
| 88 | 10.58 | 858 | 12.3 | 81.1 | 64.3 |
| 176 | 17.86 | 968 | 18.5 | 54.2 | 44.2 |
| 352 | 20.15 | 936 | 21.5 | 46.4 | 37.6 |
| 528 | 22.32 | 955 | 23.4 | 42.8 | 34.8 |
| **704** | 22.27 | 972 | **22.9** | **43.6** | **35.6** |
| 1,056 | 22.17 | 967 | 22.9 | 43.6 | 35.6 |
| 1,408 | 22.12 | 973 | 22.7 | 44.0 | 35.9 |
| 1,760 | 22.13 | 974 | 22.7 | 44.0 | 35.9 |
| **2,000** | 22.15 | 977 | **22.7** | **44.1** | **36.0** |

**Plateau: 22.7–22.9 jobs/s per kW, 43.6–44.1 J per job (35.6–36.0 J above idle).** Package power
saturates at ~970 W from level 176 onwards while throughput keeps climbing to 528, so efficiency
peaks at the plateau rather than at low load: a job costs 109 J at c=44 but 44 J at c=528+. Idle
draw is 18 % of the packed draw.

Clock, measured per the kit's intent (busy cores, not a whole-machine mean): **4.155 GHz** on a
single busy core at light load, **3.276 GHz** all-core during the packed rungs → **−21 %**.

Caveat for cross-host comparison: this is processor-package power only. Vera's "AP Power" is the
nearest equivalent domain but Vera's "Total Power" includes on-module LPDDR, so the two must not be
mixed — and the DRAM of this box is not counted in the 970 W.

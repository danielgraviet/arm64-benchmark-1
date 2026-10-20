# Sandbox create path on HQ Vera — per-step measurements (2026-10-14)

Every step of creating one Linux sandbox, from the client's `POST /vms` to the first command answered inside it,
measured per sandbox on the HQ Vera cell. Three load levels: unloaded (one at a time), a 1,000-sandbox burst with an idle
image, and a 1,000-sandbox burst with the agent image whose entrypoint runs a CPU-heavy job.

Cell: daytona `f0611fa13` (+ EROFS 4k, `RLP_FC_SOCK_WAIT_MS=30000`), daemon `rlp-rs-0.4.1`, Firecracker v1.16.1,
kernel `6.17.0-1032-nvidia-64k`, 2 × 88 cores × SMT2 (352 CPUs), unpinned, host idle before each run. Sandboxes: 1 vCPU,
0.025 CPU, 64 MiB, 1 GiB disk, template snapshot already built (clone path, `template=hit`).

## How it was measured

Everything (client, API, NATS, runner, proxy, guests) runs on the one host, so every timestamp is on the same clock.
No code was changed; five sources are joined per sandbox by `vm_id`:

| source | what it gives | tool |
|---|---|---|
| client | POST sent / answered, `running` seen, exec sent / answered (ns) | `stepclient.py`: raw HTTP, server long-poll `GET /vms/{id}?wait=running` (no client polling) |
| API audit log | request reached the API handler (`audit_logs.created_at`) | Postgres |
| API database | create transaction start (`vms.created_at`), `started_at` write-behind | Postgres |
| NATS | job stored in JetStream (ns, from the ack subject), runner ack, every `events.vm.*` | `natstap` (passive subscriber; keeps ids only) |
| runner journal | `boot-phases create` (queue, admission, image), `boot-phases` (clone sub-phases), `running-emit` | journald |

Kernel-side detail came from `bpftrace` (cgroup, fork, fsync, file-open latencies), `tcpdump` (toolbox probe) and
`iostat`. Scripts: `scripts/` (stepclient.py, natstap/, steps-run.sh, steps-analyze.py, steps-combine.py, *.bt).

## The steps

```
client ──POST /vms──► API: auth+audit → validate/scaffold/DB lookups → BEGIN, INSERT vms+jobs → JetStream publish (ack) → COMMIT → 200
                                                                               │
                         JetStream JOBS ── consumer (MaxAckPending 256) ──► runner handler (semaphore 512)
runner: admission/reserve → image resolve → manifest+template lookup → clone:
        netns from pool → cp scratch (+16 MiB init-disk copy + fsync) → cgroup mkdir → rlp-fcns (setns, join cgroup) → firecracker
        → snapshot load+resume → TCP probe :2280 until accept → register → running event ──► NATS ──► API overlay ──► long-poll answers client
client ──POST {toolbox}/{id}/process/execute──► proxy ──► guest daemon :2280 → `echo ready`
```

## Results (ms, p50 / p90)

| step | unloaded (200 sequential) | 1k burst, idle image | 1k burst, idle image, scratch on tmpfs | 1k burst, agent image |
|---|---|---|---|---|
| 1 client → API (HTTP, auth, audit) | 1.2 / 1.3 | 58 / 105 | 58 / 97 | 58 / 274 |
| 2 API handler before the DB transaction | 2.4 / 2.7 | 93 / 188 | 88 / 103 | 405 / 417 |
| 3 API DB insert + JetStream publish | 1.1 / 1.4 | 1.9 / 7.0 | 2.3 / 3.5 | 2.8 / 124 |
| 4 API commit + HTTP response | 0.6 / 0.8 | 36 / 85 | 48 / 67 | 29 / 97 |
| 5 queue: JetStream → runner handler | 0 / 0.3 | **1,226 / 2,267** | 714 / 1,593 | 559 / 9,316 |
| 6–7 runner admission + image resolve | 0 / 0 | 0 / 3 | 0 / 1 | 0 / 2 |
| 8 runner boot prep (manifest, template lookup) | 1 / 1 | 2 / 54 | 1 / 4 | 1 / 39 |
| 9a network namespace from pool | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| 9b scratch copy + 16 MiB init-disk copy + fsync | 7 / 8 | **313 / 756** | 10 / 70 | 192 / 503 |
| 9c Firecracker spawn (incl. cgroup join) + API socket | **39** / 45 | 54 / 191 | 97 / 188 | 366 / 6,925 |
| 9d snapshot load + resume | 6 / 7 | 8 / 60 | 8 / 32 | 21 / 142 |
| 9e guest toolbox port accepts | 2 / **580** | 3 / 11 | 3 / 6 | 4 / 15 |
| 9f other: cgroup mkdir, register, entrypoint trigger | 3 / 4 | **157 / 417** | 498 / 637 | 1,091 / 6,968 |
| 10 running event → NATS | 0.9 / 1.3 | 0.7 / 1.1 | 0.8 / 1.2 | 0.9 / 1.5 |
| 11 API sees running → long-poll answers client | 1.2 / 1.6 | 1.8 / 137 | 1.3 / 2.6 | 1.7 / 107 |
| **POST → client sees `running`** | **65 / 644** | **2,086 / 3,159** | **1,494 / 2,437** | **8,417 / 18,888** |
| 12 first exec through the proxy (`echo ready`) | 21 / 26 | 20 / 28 | 22 / 28 | 25 / 56 |
| **POST → first exec done** | **88 / 662** | **2,095 / 3,169** | **1,518 / 2,460** | **8,520 / 18,907** |

Samples: unloaded 200; idle-image burst 3,998 (4 runs); tmpfs 2,000 (2 runs); agent 1,000. Steps 1–4 (API) and 5–11
(runner) run in parallel after the job is stored, so the totals are not the sum of the column.

## What the numbers say

**1. Unloaded, a sandbox is usable in ~88 ms.** The API takes ~5 ms (auth 1.2, handler 2.4, DB+publish 1.1, commit 0.6).
The runner takes ~59 ms, dominated by spawning Firecracker (39 ms); snapshot load is 6 ms, scratch copy 7 ms. Getting
`running` back to the client takes ~2 ms, and the first exec through the proxy 21 ms.

**2. 23% of unloaded creates stall for exactly ~580 ms after resume.** In 46 of 200 sequential creates the guest's
toolbox port took 580 ms instead of 1–2 ms; this alone moves POST → running p90 from 65 ms to 644 ms. A packet capture
shows the runner's SYNs at 0, 211 and 422 ms reaching the guest, and the guest answering **all three at once at
~557 ms**. Two different slow guests answered with the **identical guest TCP timestamp**, 559 ms later in guest time
than a fast one. The guest receives the packets but does not process them until a timer already pending in the
snapshot fires, which points at a lost wake-up (network interrupt) after snapshot restore. Same with the agent image
(586 ms). Under a burst it mostly disappears (p90 11 ms), presumably because other activity wakes the guest.

**3. Under a 1k burst, the time goes to four places** (idle image, p50 per sandbox, all-ready ~3.3 s):
- **Waiting for a runner slot (step 5): 1.2 s.** The JetStream consumer lets at most 256 creates be in flight
  (`MaxAckPending`), so the queue length is set by how long each clone takes under load (~0.55 s).
- **Init-disk copy + fsync (9b): 313 ms.** Each clone copies a 16 MiB init disk to `/mnt/data/rlp/scratch` on the
  root NVMe and calls `fsync` (`vm.go:2465`, `template.go:1305-1338`). A 1k burst writes ~16 GB: the NVMe runs at
  ~6 GB/s and 97% utilization for ~2 s, individual fsyncs take 64 ms–1 s. (`cp` of the scratch file itself: 2–8 ms.)
- **cgroup creation (9f): 157 ms.** `mkdir` in `rlp.slice/vms` costs ~1 ms of kernel work but creates serialize, so
  each one waits in line (64–512 ms per mkdir at peak). Measured floor on this host: 1,000 cgroups with the
  `cpuset cpu memory` controllers take **0.92 s even with 256 in parallel**; with only `cpu` (all the runner uses:
  `cpu.weight`), 0.49 s.
- **API under 1,000 simultaneous POSTs: ~190 ms** (steps 1–4), mostly the handler's pre-transaction DB lookups
  (step 2: 2.4 → 93 ms). Follow-up below: not the DB pool; the 128-connection accept backlog (#3269).

**4. Moving the scratch directory to tmpfs removes the disk cost and cuts the burst by ~28%** (POST → running p50
2.09 → 1.49 s, p90 3.16 → 2.44 s). The saved time moves straight into the cgroup step (9f 157 → 498 ms), confirming
cgroup creation as the next serial bottleneck.

**5. With the agent image, everything on the runner is CPU-starved** (Firecracker spawn p90 6.9 s, cgroup step p90
7.0 s, queue p90 9.3 s): the guests' entrypoint job fills the CPUs. Unloaded, the agent image behaves exactly like
alpine (POST → running p50 67 ms), so the image itself does not slow the create path.

**Steps that are not a problem:** NATS hops (<1 ms each way), netns acquire (0 ms, pre-warmed pool), image resolve,
template lookup, snapshot load (6–8 ms), the long-poll (1–2 ms at p50), the exec path (~21 ms).

## Ruled out while looking for the burst bottleneck
| suspect | result |
|---|---|
| Go fork serialization (`cp`, `rlp-fcns`, `nft`: 3 forks per clone) | forks overlap (peak 36 concurrent); a fork is in progress only 31% of the burst |
| cgroup2 `favordynmods` (cheaper cgroup join) | joins got shorter in some runs, end-to-end unchanged (1.8–2.1 s vs 2.0 s) |
| `RLP_VM_MAXACK` 256 → 1024, KVM `halt_poll_ns` 0 | no effect (earlier today) |

## Improvement candidates (platform), largest first
1. **Stop writing 16 GB per 1k burst**: the private init disk only needs to be a writable target (comment at
   `template.go:1305`); create it sparse/reflinked, skip the `fsync`, or place it on tmpfs. Measured upper bound of the
   gain: −28% burst time.
2. **Cheaper cgroups**: enable only the `cpu` controller under `rlp.slice/vms` if cpuset/memory are unused there
   (halves mkdir cost), or pre-create cgroups in the warm pool like network namespaces, or `CLONE_INTO_CGROUP`.
3. **Resume stall (580 ms, 23% unloaded)**: root-caused below; a permanent neighbour entry per netns removes it (#3265).
4. **API under bursts**: the pool is fine; the accept backlog (128) is not (#3269).
5. **Instrumentation**: cgroup setup, init-disk copy, deliveries and the post-running ack have no timer of their own;
   `deliver_ms` mixes queueing and semaphore wait.

## Follow-up: the 580 ms stall, root-caused (→ daytona/rlp#3265)

Traced with `bpftrace` on the tap device and KVM events (30 sequential creates, one guest at a time):

1. Every guest answers a SYN that reaches its tap in 0.1–0.3 ms. The delay is before the tap.
2. Before the first SYN, the host side of the netns ARPs for the guest: **53 of 60** pool netns hold a `FAILED`
   neighbour entry for the guest IP. Fast clones answer the ARP in 0.5–1 ms. In slow clones the ARP is queued
   2.4–3.6 ms before the vCPU first runs, **no network interrupt (IRQ 36) is ever raised for it**, and it goes
   unanswered. Linux would only retry after `retrans_time_ms` = 1 s.
3. The daemon's resume announcement (`garp.rs`, `RESUME_JUMP` = 2 s monotonic overrun) **never fires on arm64**: the
   guest's monotonic clock resumes at the snapshot instant (uptime 1.15 s in every clone). The guest's wall clock is
   frozen too, **2 h 52 min behind** (added to daytona/rlp#767).
4. The guest's 1 s keepalive ARP, whose phase is frozen in the template, finally resolves it at +558 ms, the same in
   every slow clone of the template.

**Fix-shaped A/B, no code change:** a permanent neighbour entry for the guest (`10.255.0.2 → AA:FC:0A:FF:00:02`,
deterministic `macFromIP`) in every pool netns: stalls **16/60 (27%) → 0/60 → 15/60 (25%)** after removing it again.

## Follow-up: the API under a burst (→ daytona/rlp#3269)

- **The DB pool is not the bottleneck.** At the default 64, at most 16 connections were active (0.25 s samples);
  256 vs 64 made no end-to-end difference (POST → running p50 1.73–1.87 s either way). API CPU peaks at 3–4 cores.
- **The API listens with backlog 128** (`tokio::net::TcpListener::bind` → mio's hard-coded 128, `api/src/main.rs:847`).
  1,000 new client connections overflow it: `TcpExtListenOverflows` +~550 per burst, and step 1 (client → API)
  clusters at 1.03 s / 2.05 s, the TCP retransmit timers.
- **With connections opened beforehand (0 overflows), the API's whole share is ~110 ms** under 1,000 concurrent
  creates (auth 30, handler 36, DB+publish 1.4, commit+response 40 ms at p50).
- End-to-end, today's burst time does not change: requests that arrive sooner wait longer in the runner queue
  (step 5: 0.72 → 1.16 s). The fix matters once #3260/#3261 are fixed, and for individual creates during bursts.


## Corrected results: the same measurements with the four fixes applied (2026-10-14, patched build)

All four issues were patched on the bench cell, each behind an env flag defaulting to today's behaviour, so the
control arm is the *same binary* with the flags unset. Patches: `patches/runner-fixes.diff`, `patches/api-backlog.diff`.

| flag | fixes | what it does |
|---|---|---|
| `RLP_INITDISK_MODE=nofsync\|sparse` | #3260 | drop the per-clone init-disk fsync (or write no data at all) |
| `RLP_CGROUP_POOL=<n>` | #3261 | pre-create per-VM cgroups off the hot path, filled from runner start |
| `RLP_NEIGH_PERMANENT=1` | #3265 | permanent neighbour entry for the guest on the inner tap |
| `RLP_API_LISTEN_BACKLOG=4096` | #3269 | explicit accept backlog instead of mio's 128 |

**1,000 sandboxes, idle image, 16 client processes** (ms, p50 / p90; control = 4 runs, ALL = 2 runs):

| step | control | +initdisk<br>(nofsync) | +cgroup<br>pool | +API<br>backlog | **ALL** |
|---|---|---|---|---|---|
| 1 client → API | 40 / 1072 | 41 / 1066 | 49 / 1077 | 34 / 51 | **32 / 61** |
| 2 API handler before DB txn | 18 / 80 | 13 / 22 | 30 / 35 | 87 / 451 | 45 / 72 |
| 3+4 API DB insert, publish, commit, response | 10 / 35 | 13 / 39 | 24 / 37 | 14 / 122 | 13 / 55 |
| 5 queue → runner handler | 793 / 1247 | 337 / 822 | 629 / 964 | 1214 / 2180 | **421 / 1172** |
| 9b scratch + init-disk copy | 300 / 700 | **9 / 20** | 516 / 689 | 126 / 959 | **11 / 35** |
| 9c Firecracker spawn + API socket | 63 / 180 | 106 / 219 | 60 / 137 | 56 / 144 | 200 / 289 |
| 9d snapshot load + resume | 12 / 69 | 39 / 148 | 11 / 39 | 94 / 381 | 20 / 58 |
| 9e guest toolbox accepts | 3 / 11 | 4 / 478 | 3 / 14 | 4 / 462 | 5 / 76 |
| 9f cgroup mkdir, register, trigger | 201 / 381 | 427 / 565 | **24 / 58** | 123 / 495 | 139 / 269 |
| 11 API → long-poll answers client | 3 / 89 | 2 / 4 | 61 / 250 | 2 / 65 | 1 / 4 |
| **POST → client sees `running`** | **1927 / 3035** | 1600 / 2709 | 1725 / 2653 | 2296 / 3370 | **1054 / 1748** |
| **POST → first exec done** | **1937 / 3055** | 1621 / 2728 | 1743 / 2664 | 2320 / 3394 | **1071 / 1777** |
| listen overflows during the burst | 424–687 | 460 | 656 | **0** | **0** |

**60 sequential creates, idle host** (ms):

| | control | +permanent neighbour | ALL |
|---|---|---|---|
| POST → `running` p50 / p90 / p99 | 67 / 75 / **658** | 66 / 73 / **81** | **64 / 69 / 73** |
| clones stalled (`toolbox_wait_ms` > 100 ms) | 4 / 60 | **0 / 60** | **0 / 60** |
| max `toolbox_wait_ms` | 580 | **2** | **2** |

### What the corrected numbers say

- **Unloaded, a sandbox is usable in ~85 ms and the 580 ms tail is gone** — p99 658 → 73 ms. That is the fix users feel.
- **A 1k burst is ~45% faster**: p50 1.93 → 1.05 s, p90 3.04 → 1.75 s, with no client-visible failures in 2,000 sandboxes.
- **Each fix alone moves 10–20%; they only pay off together.** Removing the init-disk I/O hands the time to cgroup
  creation; fixing the backlog alone is *slightly worse* end-to-end (2.30 s) because requests stop waiting on TCP
  retries and start waiting in the runner queue instead.
- **The cheap fix is enough for #3260.** `nofsync` takes 9b from 300 ms to 9 ms; `sparse` to 5 ms. The extra 4 ms is
  not worth depending on "the guest never reads vda".
- **A warm pool is the whole point of #3261.** Filled lazily on first use it does nothing under burst (9f stays at
  454 ms, the kernel makes ~1160 cgroups/s and the burst eats them faster); filled from runner start it is 24 ms.
- **The bottleneck moved, as expected.** In the ALL arm the biggest remaining steps are the queue for a runner slot
  (421 ms, still the 256 `MaxAckPending` cap) and Firecracker spawn (200 ms, up from 63 — more clones now reach that
  stage at once). Those are the next things to attack.

**Cell state:** patched binaries installed with every flag unset, i.e. stock behaviour (the four control arms confirm
it reproduces the pre-patch baseline). Stock binaries kept at `/usr/local/bin/rlp-runner.bak-prepatch` and
`/opt/rlp/rlp-api.bak-prepatch`. Nothing is merged upstream; the patches are measurement builds.


## Harness benchmarks with all four fixes (2026-10-14 evening, `fixes-bench.tgz`)

Same patched binaries, flags off vs on, interleaved (off, on, off, on); HQ Vera unpinned (both sockets).
Startup = `mpfleet.py --procs 16 --count 1000` (harness logic, SDK polling 0.25 s ×1.5 → 2 s);
throughput = published dense ladder (agent bench, n=45, -E 8, hold-then-exec). Harness client read timeout set to
120 s (`RLP_HTTP_READ_TIMEOUT_S`, new opt-in in `harness/rlp_client_tuning.py`) after the first attempt hung
forever on wedged guests.

**Startup, 1,000 sandboxes, idle image (`alpine:3.20`)** — 3 reps each:

| | fixes off | fixes on |
|---|---|---|
| create p50 | 2.07 / 2.39 / 2.32 s | **1.51 / 1.62 / 1.59 s** (−30%) |
| create p95 | 3.30 / 3.76 / 3.46 s | **2.54 / 2.61 / 2.56 s** (−27%) |
| all ready (clean runs) | 4.70 / 3.86 / 3.66 s | 3.88 / **2.69** s (one rep: 10.4 s, held by 1 failed sandbox) |
| failed sandboxes | 0 / 0 / 0 | 1 / 0 / 0 |
| API listen overflows | 210 / 0 / 447 | 0 / 0 / 0 |

**Startup, 1,000 sandboxes, agent image** (entrypoint runs `workload.agent`): **no change** — p50 11.8–13.6 s off vs
7.6–13.7 s on, p95 21.6–25.6 s vs 21.7–26.1 s. The guests' CPU work dominates; the fixes are not in its way.

**Throughput ladder (jobs/s)**:

| level | fixes off | fixes on |
|---|---|---|
| 176 | 1.47 (8 runs hung 120 s in a wedged guest) | 15.17 |
| 352 | 26.67 | 26.65 |
| 704 | 25.93 | 25.69 (4 failures) |

**No throughput change**, as expected: ~99% of a job is in-guest work. The 176 rung with fixes off measures the hang,
not the platform.

**Takeaways**
- With the published harness method, the fixes cut idle-image startup ~30% (p50 2.3 → 1.6 s, p95 3.5 → 2.6 s). That is
  less than the −45% seen with the long-poll client, because SDK polling (0.25 s ×1.5 up to 2 s) adds its own
  granularity on top of the platform time.
- Agent-image startup and throughput are unchanged: they are bound by guest CPU work, not the create path.
- **The tail is now set by guest failures, not the platform.** All-ready and the 176 rung were each held by 1–8
  sandboxes whose guests wedged after resume: 2 of 176 guests in one run had kernel oopses ~1.3 s after boot (NULL
  dereference in `bash`, list-poison address in `python`; 1-vCPU, the #3213 family). Rate is the same with fixes off
  (10 failures) and on (7 failures), so the fixes neither cause nor cure it.
- Harness gap: the SDK reads with no timeout, so one wedged guest hangs a ladder forever. The opt-in
  `RLP_HTTP_READ_TIMEOUT_S` (installed on the Vera harness copy, uncommitted) turns that into a counted failure.


### Follow-up: the guest crashes behind those tails (→ daytona/rlp#3213)

Reproduced with sandboxes kept alive so serial logs survive (`oops-1vcpu.tgz`). **1-vCPU clones oops at ~0.2%**, all
10–30 ms after resume, in the entrypoint process:

- 2 of 3 identical: `__handle_mm_fault` with **`x0 = dead000000000122` (LIST_POISON2)** — the guest walks a freed,
  poisoned list entry while servicing an ordinary user-space page fault.
- the third: `touch_atime` ← `filemap_read` ← `erofs_file_read_iter` ← `ovl_read_iter` ← `kernel_read` in `bash`,
  with a garbage `struct file` pointer.

| population | clones | oopsed | client-visible failures |
|---|---|---|---|
| 5 freshly built templates × ~300 clones | 1,497 | 3 (0, 1, 2, 0, 0 per build) | 7 |
| one older template | 2,000 | 0 | 4 (`exitCode -1`) |

Same class as the 2-vCPU `__rb_erase_color` oops (mm-metadata walk), and every victim is a process created at the
snapshot/resume boundary — the snapshot-timing hypothesis. Per-template variance is suggestive (0/2,000 on one
template is unlikely at a uniform 0.2%) but needs ~2,000 clones per build over ~10 builds to establish.

## Issues filed from this work
| issue | what |
|---|---|
| daytona/rlp#3260 | 16 MiB init-disk copy + fsync per clone (−28% burst time when removed via tmpfs) |
| daytona/rlp#3261 | per-sandbox cgroup creation serialized, ~0.9 s per 1,000 on 352 CPUs (memory controller) |
| daytona/rlp#3265 | ~25% of arm64 clones stall ~580 ms: lost first ARP + resume GARP never fires; permanent neighbour fixes it |
| daytona/rlp#3269 | API accept backlog 128 → ~1 s retransmits for ~half of a burst's new connections |
| daytona/rlp#767 (comment) | arm64 guest wall clock = template age behind; monotonic clock does not jump |

Each issue now carries its own A/B result as a comment.

## Other things found
- **Leak:** `/mnt/data/rlp/scratch` holds 1,460 orphaned `*.initdisk.ext4` (23 GB) from the 01:34 UTC window
  (aborted runs). Today's clean runs did not add any.
- **Failures in ~6,000 measured creates:** 1 post-resume hang (status `running`, `echo ready` timed out after 30 s),
  the case daytona/rlp#3229 describes.
- The runner derives its disk capacity from the scratch filesystem's size: a 96 GB tmpfs admitted only ~95 sandboxes
  (`capacity gate … nak-routing to a peer`), and the rest expired after 60 s. Needs a large tmpfs for this test.
- `mount -o remount` cannot switch `favordynmods` off again (util-linux merges options); use
  `mount --options-source=disable -t cgroup2 -o remount,<full list> cgroup2 /sys/fs/cgroup`.

## Host state after the measurements
Runner back on `/mnt/data/rlp/scratch`, no drop-ins, cgroup mount `rw,nosuid,nodev,noexec,relatime,nsdelegate,
memory_recursiveprot` (original), unpinned, tmpfs removed, 0 sandboxes. Every change is logged in
`/etc/rlp/HOSTCHANGES`.

Raw data: `create-path-steps.tgz` (all `steps-*` run directories with client, tap, runner, DB and per-sandbox
`steps.jsonl`; the toolbox pcap; bpftrace outputs).

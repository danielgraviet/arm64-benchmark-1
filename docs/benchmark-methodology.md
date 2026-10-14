# Benchmark methodology — what distorts sandbox benchmarks, and how to avoid it

Learned on HQ Vera, OCI Vera, EPYC 9575F, EPYC 9755 and Vultr 9745 (Sep–Oct 2026). Every rule below exists
because breaking it produced a wrong published number or a wrong conclusion at least once. Evidence for each:
`/mnt/data/bench/FINDINGS.md` on the HQ Vera cell, and issues daytona/rlp#3212, #3213.

## 0. The image's entrypoint runs in every sandbox — use an idle image for startup

`dtgraviet/vera-agent-benchmark:v3` has the entrypoint `python -m workload.agent --n 30 --seed 42`. The runner releases
the entrypoint gate on every sandbox, so **every sandbox in a create-ready burst runs a CPU-bound job as soon as it is
`running`** (measured: 1.0 core for ~3.1 s per sandbox on a quiet host). A 1k burst therefore measures startup *while
~3,000+ core-seconds of guest work compete with it*, and the host sits at 100% for 30+ s.

Same 1k burst (16 client processes), agent image vs `alpine:3.20` (entrypoint exits immediately), 2026-10-14:

| host | image | all-ready | p95 | host CPU during burst |
|---|---|---|---|---|
| HQ Vera, pinned to 1 socket | agent | 10.2–10.4 s | 9.6–10.0 s | socket 100% for 37 s |
| HQ Vera, unpinned | agent | 22.0–22.5 s | 21.9–22.3 s | up to 350 cores |
| EPYC 9575F | agent | 24.5–31.5 s | 19.7–21.9 s | host >95% for 36 s |
| HQ Vera, pinned or unpinned | **alpine** | **4.0–4.2 s** | **3.8–4.2 s** | ≤ 38 cores peak |
| EPYC 9575F | **alpine** | **4.0 s** | **3.9 s** | ≤ 33 cores peak |

**The platform startup path is the same ~4 s on both hosts.** The "startup" gap seen with the agent image is the
hosts' CPU throughput on the entrypoint workload, not startup.

**Rules**
- **Measure startup with an idle-entrypoint image** (`MPFLEET_IMAGE=alpine:3.20 mpfleet.py …`), and report the image.
- A burst with the agent image is a *startup-under-load* test. Label it that way, never as "startup".
- Watch for it: if the host stays busy after the last sandbox is ready, the guests are doing work.

## 1. Reading the numbers (`create-ready` / `rlp_light_create_fleet.py`)

| field | what it actually is | trap |
|---|---|---|
| `ready_wall_s` | burst start → last sandbox ready **and probed** | One hung sandbox turns it into the client timeout (60–186 s). Report the median and p95 too, and the failure count. |
| `create_s` | one `client.create()`: POST /vms + GET /vms/{id} + polling until `running` | Includes client queueing. |
| **`post_s`** | `create_s` − `wait_s`: **not "control plane accepts the request"** | With 1,000 threads in ONE Python process it is mostly **the harness queueing on the GIL**. Measured on HQ Vera, 1k burst: 1 process → post p50 2.9–5.8 s; 16 processes → **0.23–0.50 s**, all-ready unchanged (9–12 s). |
| `wait_s` | polling until `running` | Polling granularity (0.25 s ×1.5 → 2 s backoff) rounds it up; single-sandbox numbers are dominated by the poll interval (0.5 s fixed poll → every 1-sandbox create "takes" ~520 ms; at 10 ms polling it is ~70 ms). |
| `probe_s` | `echo ready` through the toolbox proxy | The proxy path; ~30–45 ms p50, 200–380 ms p99 at 1k–2k. |

**Rules**
- **Use more than one client process for bursts ≥ 500**: `mpfleet.py --procs 16 --count 1000` (same per-sandbox logic,
  barrier start, absolute timestamps). Report `procs` with every result.
- **Never label `post_s` from a single-process client as control-plane time.** If you need the API's share, enable API
  tracing (OTel) and read server-side `POST /vms` durations.
- Compare platforms on **all-ready + median + p95 + failures**, with the same client settings (pool, polling, procs).

## 1b. One wedged guest can hang a whole run — set a client read timeout

The SDK reads with no timeout (`httpx.Timeout(30.0, read=None)` in `rlp/http.py`). A guest that wedges mid-exec —
a post-resume kernel oops, or the daemon answering TCP but never finishing a command (daytona/rlp#3213, #3229) —
therefore hangs that call **forever**: the daemon-side command timeout never fires, because the daemon is the thing
that is stuck.

Measured on HQ Vera: a dense ladder at level 176 sat for 20 minutes with **1,401 of 1,408 episodes finished and 7 in
flight**; two of the 176 live guests had oopsed ~1.3 s after resume. The run never ended on its own.

- Set **`RLP_HTTP_READ_TIMEOUT_S`** (harness knob, `harness/rlp_client_tuning.py`; unset = the SDK's no-timeout
  behaviour). 120 s is a good value when episodes are 7–30 s: a wedged guest becomes a counted failure instead of a
  stall.
- Always run a ladder under an outer `timeout`, and report failures per level.
- A level whose throughput collapses while the host is idle (`load average` near zero, sandboxes alive) is this,
  not the platform: at level 176 with no read timeout the rung read 1.47 jobs/s against 15.2 jobs/s on the same
  build minutes later.

## 2. Host state that silently changes results — check every run

Run `scripts/host/bench-preflight.sh <outdir>` before every rep. It refuses to start (exit 1) on the hard gates and
records the rest. Hard gates and why:

| gate | what happened when it was wrong |
|---|---|
| no `rlp-cpu-weight-floor.sh` | a hand-started busy loop (one `cat` fork per sandbox per pass) **doubled** 9575F startup (1k median 18.6 → 9.7 s when stopped) and was running during published runs |
| no other CPU load > 20 % (live 3 s sample, not `ps` lifetime %) | catches the above, a filling netns pool, udev storms |
| netns pool ≥ 95 % of `RLP_NETNS_POOL` | a refilling pool burns CPU for ~10 min after every runner restart |
| no leftover firecracker / live rows | leftovers inflate the next rep and its failure count |
| `vm.nr_hugepages = 0` | the E2B image reserves 1.44 TB of 512 MiB hugepages at boot → ~2 GB usable → OOM kills |
| ARP `gc_thresh3 ≥ 65536` (v4 + v6) | default 1024 caps a host at ~1,000 sandboxes |
| `RLP_BALLOON=0` on 64 KiB-page hosts | the balloon corrupts guest memory (#1066) |
| client `nofile` hard ≥ 1,048,576 | `EMFILE` failures above ~1k |

Recorded (report them with results): CPU, sockets online, kernel + **page size**, full cmdline (`preempt=`, `kvm-arm.mode`,
`init_on_alloc`, `numa_balancing`), governor/idle driver, **power cap**, binary SHAs, build commit, runner/API env,
**cpuset of `rlp.slice` and of the control plane**.

## 3. Placement (dual-socket hosts)

- **Placement matters when the guests do CPU work, not for the startup path itself.** With the agent image
  (§0) a 1k burst on HQ Vera takes 8.4–10.6 s pinned to socket 0 vs 20–23 s spread over both sockets. With an idle image,
  pinned and unpinned are the same (~4 s). An earlier reading of this as "NUMA is the startup lever" was wrong.
- **Throughput: say how many sockets.** HQ Vera dense ladder (published recipe): one socket 13.0–14.0 jobs/s,
  both sockets 26.6 jobs/s at 352. The published 13.3 jobs/s was a one-socket configuration.
- So a "one socket" result must say exactly what was pinned. Pin with `rlp.slice` + `rlp.slice/vms` `cpuset.cpus` and
  **`cpuset.mems`**; control-plane services with `systemctl set-property --runtime <ONE unit> AllowedCPUs= AllowedMemoryNodes=`;
  containers with `docker update --cpuset-cpus --cpuset-mems` (no `-q` flag). **Verify every placement from
  `/proc/<pid>/status` (`Cpus_allowed_list`, `Mems_allowed_list`)** — both commands fail silently in scripts otherwise.
- A pin on `rlp.slice` survives runner restarts. Undo it explicitly.

## 4. Software that must match across platforms

- **Same Daytona build** (runner, API, proxy) on every platform being compared. Record the commit. Old builds without
  the sudo-storm fix (`1b2da010a`) behave differently under burst.
- **Same in-guest daemon** — every AMD cell runs `rlp-rs-0.4.1`; the harness SDK (`rlp-sdk 0.4.0`, `~/rlp/clients/python`)
  uses its `/process/execute` route, which newer daemons removed.
- **Same client** (harness copy + SDK), same pool/polling/disk/`procs`.
- **Same guest shape.** `RLP_BURST_MAX_CPU` decides the vCPU count of creates that set no `cpu_max`. The old HQ Vera cell
  ran cap 2 → 2-vCPU guests; most hosts ran cap 1. 2-vCPU snapshot clones fail 20–55 % on Vera (#3213).
- Firecracker: record the binary SHA. The NVIDIA SMT fork used on the old HQ cell (`v1.16.1-rlpsmt1`) can no longer be
  rebuilt (upstream commits force-pushed away); it is inert for 1-vCPU guests.
- `RLP_FC_SOCK_WAIT_MS=30000` (bench runner): the hard-coded 3 s Firecracker socket wait fails healthy-but-slow spawns
  under burst (491/3k on Vera, 11,384 in a day on the 9575F), feeding retries and self-cordons (#3212).
- Tuning that made **no measurable difference** (don't apply it per-platform): `RLP_EVENT_AUDIT=0`, quiet-progress runner,
  `cpuidle.off=1 init_on_alloc=0`, API restarts / accumulated rows, scaling the toolbox proxy (1 vs 4 behind HAProxy:
  identical; one proxy uses ~1 CPU-s per 1k burst).

## 5. Setting up a cell — gotchas

- systemd: **`EnvironmentFile=` beats `Environment=`**. A drop-in `Environment=X` loses to `X` in `runner.env`/`api.env`.
  Override with a second `EnvironmentFile=` in a drop-in.
- 64 KiB-page hosts: EROFS layers must be built with `mkfs.erofs -b 4096` (runner fix PR #1060 + the daemon layer script).
- A fresh DB has no `vera` CPU type: `insert into cpu_types (id,name,cpu_arch,tier) values ('vera','NVIDIA Vera','arm64',3)`
  and `RLP_RUNNER_CPU_TYPE=vera`, or every `--target vera` create 400s.
- After swapping runner builds, delete **all** `rlp_*` nft tables and netns; stale anti-spoof sets from a newer runner
  drop every guest reply.
- `/etc/hosts` must contain the hostname, or every `sudo` blocks on DNS (113 s / >25 s per call on both RedSwitches hosts).
- Host services reacting to every sandbox veth: the unfiltered `70-iscsi-network-interface.rules` (shadow it to skip
  `rlp*|veth*|tap*|fc*`), `libvirtd`, `fwupd`.

## 6. One operator at a time

Two operators on one box invalidate each other's runs (HQ Vera, 2026-10-14: an operator's runner restart killed a run,
the other's binary swap overwrote theirs, and drop-ins from one leaked into the other's arms). Before benchmarking:
`tmux ls`, `w`, `ls /etc/systemd/system/rlp-*.service.d/`, and agree who has the box.

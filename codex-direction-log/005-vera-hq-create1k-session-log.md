# HQ Vera create-ready 1000 session log

Plain-language timeline of bringing HQ Vera back to the Sep 8 create-ready result (about **11 seconds** for 1000 sandboxes). Technical detail is kept so eng can act on it.

**Target:** 1000 creates, 0 fails, wall clock about 11 s (Sep 8 clean was about 10.7–10.8 s).  
**Published Sep 8 shape:** socket 0 pin `0-87,176-263`, disk 1 GiB, cpu 0.025, mem 0.0625 GiB, image `dtgraviet/vera-agent-benchmark:v3`, probe `echo ready`.

**Outcome (2026-10-14):** wall time **reproduced** on two clean runs (**10.98 s** and **11.16 s**, both **1000/0**). Median create is still higher than Sep 8 (~6.2–6.4 s vs ~3.5–3.7 s). A third confirm was interrupted by another operator restarting the API.

---

## Main blockers (what stopped ~11 s at first)

These are the big reasons we could not trust or reach a Sep 8–style 1k until they were fixed.

1. **No socket pin**  
   Runner and VMs could use the whole machine. Sep 8 was pinned to socket 0 (`0-87,176-263`). Without that, the published single-socket result is not comparable.

2. **Runner marked `lost` (heartbeat contract mismatch)**  
   systemd said `rlp-runner` was active and `/health` was OK, but the API listed `vera-1` as **lost**. Creates returned **HTTP 400** (“no online linux-class runner”).  
   Cause: we rebuilt the runner from the **SDK pin** checkout (`660e6e3b`). That older runner source omitted required heartbeat fields `capabilities.classes` and `capabilities.windows`, so the API rejected heartbeats.

3. **Quiet-progress rebuild vs sudo limiter**  
   Rebuilding for quiet progress from the wrong tree risked shipping a binary **without** the sudo concurrency limiter (`RLP_PRIV_EXEC_CONCURRENCY`). That had to be caught before measuring.

4. **Netns pool thrash**  
   The runner needs a full pre-built network-namespace pool (~2100). Fighting `RLP_VM_CONCURRENCY` (wrapper wanted 256, env already had 512) caused **restarts** and forced the pool to rebuild over and over.

5. **Udev stampede**  
   Filling thousands of netns created a flood of device events. Hundreds of udev workers blocked (~650–700), load spiked, and the box was not idle enough to measure.

6. **Cold / broken template path**  
   First measured attempt after repairs failed **0/1000** because the daemon layer pointer was refused (missing `erofs_sha256`). That wall is not a ready result.

7. **Shared-box interference**  
   Other operators ran A/B experiments and later **restarted the API mid-fleet**. One confirmation ended **934/66** with connection-refused errors. Not a chip result.

8. **Tooling friction (slowed us, did not define the chip number)**  
   Axis/Codex TUI auth and bubblewrap sandbox failures on the DUT. Worked around with on-box Codex + `dangerously-bypass-approvals-and-sandbox`. Soft `ulimit` started at 1024 until raised.

---

## What we did to finally reproduce ~11 s wall

1. **Pinned socket 0** with `tickets/vera-pin-single-socket.sh` and verified cgroup CPUs/mems.  
2. **Kept Python eng SDK at `660e6e3b`**, but **built the runner from a separate newer checkout** (`33ba48051`) so heartbeats include required capability fields **and** quiet progress **and** the privileged-exec limiter.  
3. **Stopped fighting concurrency 512**, let the **netns pool fill to 2100**, capped **udev** workers (~16), drained Firecrackers to **0**, waited for load to settle.  
4. **Fixed the daemon/erofs layer pointer** so templates could warm.  
5. **Ran onsite recipe:** `TARGET=vera DISK_GB=1`, nofile 65536, localhost API, burst CPU 1, snapshots on, HTTP poll pool 32 (current wrapper).  
6. **Measured only after warmup / template path was healthy.**

### Clean results

| JSONL | ok/fail | wall | create p50 / p95 / max |
|---|---|---|---|
| `daniel-focus-here/vera-jsonl/vera_create_ready_1000_20261014_012722.jsonl` | 1000/0 | **10.98 s** | 6.22 / 10.39 / 10.64 |
| `daniel-focus-here/vera-jsonl/vera_create_ready_1000_20261014_012924.jsonl` | 1000/0 | **11.16 s** | 6.42 / 10.21 / 10.72 |
| Sep 8 published (reference) | 1000/0 | ~10.8 s | ~3.7 / ~10.3 / ~10.5 |

### Still open

- **Median create** (~6.3 s) is still above Sep 8 (~3.7 s). Client split on clean runs shows large **`post_s`** (control-plane POST) and **`wait_s`** / queue-before-runner, while Firecracker start stays tiny (~10 ms).  
- Need **coordinated** uninterrupted confirms (no external API/runner restarts) if we want a three-run clean cluster.  
- Detail status: `codex-direction-log/004-vera-create1k-status.md`.

---

## Chronological notes

### Setup and how we work on this box

- HQ Vera is reached only through Axis SSH (`ssh.axisapps.io`). Coding agents on a laptop cannot drive this box the way they do a normal SSH host.
- We put **Codex on the Vera machine** and use **GitHub** to move instructions and results. The Mac mostly `git pull`s.
- Playbook: `tickets/vera-codex-host.md`. Directions live under `codex-direction-log/`.
- One-time bootstrap on the box: `uv`, `gh` auth, clone `arm64-benchmark-1`, eng Python SDK at commit `660e6e3b`, Codex install.
- Eng SDK overlay command that works here: `RLP_PIN=660e6e3b bash scripts/host/install_eng_rlp_sdk.sh` (the `bench-pin` branch name is missing on the `daytona/rlp` fallback clone).

### Early host checks (before the measured 1k)

- Host page size is **64 KiB** (`getconf PAGESIZE` = 65536). Kernel name includes `nvidia-64k`. That matches the known HQ / onsite shape.
- Soft open-file limit started at **1024**. Hard limit was already **1048576**. Soft was raised in the working shell. Recipe wrappers also raise nofile for the run.
- Neighbor table `gc_thresh3` was **65536** (healthy for large create waves).
- **Weight-floor loop** (`rlp-cpu-weight-floor`) was **not** running. That background CPU rewriter hurt Zen5 timings earlier.
- First installed runner had sudo-limiter marker present, quiet-progress marker missing.
- Socket pin was **not** set like Sep 8 until we ran the pin script.
- Idle baseline was dirty at first check: high load, leftover Firecrackers.

### Why the new environment looked slow (CTO first numbers)

- CTO’s new-env 1k medians were about **7.9–9.8 s** ready, tails about **20–83 s**.
- Sep 8 HQ was about **3.5–3.7 s** median, about **10.2–10.8 s** p95/max, wall about **11 s**.
- We treated the gap as **repro / config**, not a sudden chip regression.
- Direction for Codex: `codex-direction-log/003-vera-hq-create1k-pin.md`.

### Repo and Codex tooling hiccups

- On-box clone briefly lost `.git`. Re-cloned and reinstalled eng SDK.
- Codex TUI hit `account/read` / workspace requirements (`-32603`).
- Default bubblewrap sandbox failed (`RTM_NEWADDR`). Used full host access for `codex exec`.

### Competing work on the box

- Waited out an FC_SOCK A/B that restarted the runner.
- Later, another operator restarted the API during a confirmation fleet (66 connection-refused failures). Documented and excluded.

### Runner rebuild, udev, netns, heartbeat

- Kept SDK at `660e6e3b`. Built runner from separate tree `33ba48051` with capability fields + quiet progress + priv-exec limiter.
- Accepted VM concurrency **512** to avoid pool rebuild loops.
- Capped udev workers, drained FC to 0, waited for netns **2100/2100**.
- After capability-capable runner deploy: `vera-1|online` again.

### Measured runs (2026-10-14)

- `…012227.jsonl`: **0/1000** fail (daemon/erofs layer). Ignore wall.
- `…012722.jsonl`: **1000/0**, wall **10.98 s** (first Sep 8–band wall success).
- `…012924.jsonl`: **1000/0**, wall **11.16 s** (idle confirmation).
- `…013140.jsonl`: **934/66**, wall ~69 s, API restarted mid-run. Exclude.
- Final cleanup: FC=0, API healthy, benchmark tmux gone. Pushed through `9fe41bc` (status note updated).

---

## Quick glossary

- **Sandbox:** short-lived microVM (Firecracker) used for one unit of work.
- **Create-ready 1000:** start 1000 sandboxes and wait until a simple probe (`echo ready`) succeeds in each.
- **Wall clock (`ready_wall_s`):** time from start until the whole batch is ready.
- **Median create:** middle sandbox’s create time. Can stay high even when wall is ~11 s.
- **Socket pin:** restrict runner and VMs to one CPU socket so the result matches the published single-socket HQ run.
- **Netns pool:** pre-built set of network namespaces for sandboxes.
- **Udev:** kernel/userspace device event handling. Can stampede when many network devices appear.
- **Heartbeat:** runner periodically tells the API it is alive. Missing fields ⇒ API marks runner lost.
- **Quiet progress:** runner sends fewer intermediate status events during create.
- **Sudo limiter:** cap on parallel privileged host commands so the machine does not fork-storm on `sudo`.
- **`post_s` / `wait_s`:** client time posting create to the API, then waiting until ready.

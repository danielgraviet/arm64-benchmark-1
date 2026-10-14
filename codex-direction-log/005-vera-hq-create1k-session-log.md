# HQ Vera create-ready 1000 session log

Plain-language timeline of bringing HQ Vera back to the Sep 8 create-ready result (about **11 seconds** for 1000 sandboxes). Technical detail is kept so eng can act on it.

**Target:** 1000 creates, 0 fails, wall clock about 11 s (Sep 8 clean was about 10.7–10.8 s).  
**Published Sep 8 shape:** socket 0 pin `0-87,176-263`, disk 1 GiB, cpu 0.025, mem 0.0625 GiB, image `dtgraviet/vera-agent-benchmark:v3`, probe `echo ready`.

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
- Soft open-file limit started at **1024**. Hard limit was already **1048576**. Soft was raised to **1048576** in the working shell. New logins may fall back to 1024 unless PAM or the recipe raises it again.
- Neighbor table `gc_thresh3` was **65536** (healthy for large create waves).
- **Weight-floor loop** (`rlp-cpu-weight-floor`) was **not** running. That background CPU rewriter hurt Zen5 timings earlier. Good that it is absent here.
- **Sudo concurrency limiter** string `RLP_PRIV_EXEC_CONCURRENCY` was present in the **installed** runner binary (count 1).
- **Quiet progress** string `RLP_QUIET_PROGRESS` was **missing** from that first installed binary (count 0).
- Socket pin was **not** set like Sep 8. `rlp.slice` cpuset was empty. `rlp.slice/vms` was missing. Sep 8 had CPUs `0-87,176-263` and mems `0`.
- Idle baseline was dirty at first check: high load averages, `rlp-runner` hot, leftover Firecrackers. Not a fair measure yet.

### Why the new environment looked slow

- CTO ran three 1000-sandbox bursts on the **new** HQ environment.
- New HQ medians were about **7.9–9.8 s** ready. Tails went to about **20–83 s**.
- Sep 8 HQ was about **3.5–3.7 s** median ready, about **10.2–10.8 s** p95/max, wall about **11 s**.
- New HQ looked closer to **OCI Vera** and cleaned **9575F** than to published HQ. We treated that as a **repro / config gap**, not a sudden chip regression.
- Direction for Codex: `codex-direction-log/003-vera-hq-create1k-pin.md` (pin socket 0, onsite `DISK_GB=1`, debug to ~11 s wall).

### Repo and Codex tooling hiccups

- The on-box clone briefly **lost its `.git` directory**. Re-cloned to `85aca35` (direction note present). Reinstalled eng SDK afterward.
- Codex **TUI** started failing: `account/read` / workspace requirements (`-32603`) even after logout/login.
- `codex exec` could authenticate, but the default **bubblewrap sandbox** failed on this host: `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`.
- Workaround: run with `--dangerously-bypass-approvals-and-sandbox` (or equivalent full host access). This DUT needs localhost RLP and in-process ulimit raises.
- A clean Codex reinstall / cache clear was also attempted while waiting on other work.

### Competing work on the box

- Before our 1k, Codex found a **six-run A/B** that changed Firecracker socket wait (`FC_SOCK`, 3000 vs 30000 ms) and restarted the runner.
- We **waited** for that experiment to finish so it would not fight the pin and create-ready measurement.
- After it finished, we told Codex the box was ours again and to continue direction 003.

### Runner rebuild saga (quiet progress vs sudo limiter)

- Create-ready path wants **quiet progress** so the runner emits fewer intermediate status events (less API spam during creates).
- Rebuilding the runner from the SDK pin checkout (`660e6e3b`) added quiet progress but **dropped** the sudo concurrency limiter that the old binary had.
- Codex **stopped before the 1k**, then aimed the build path at keeping **both** quiet progress and the privileged-command limiter.
- Separately: wrapper drop-in wanted `RLP_VM_CONCURRENCY=256`, while runner env already had **512**. Fighting that caused extra **restarts and full netns pool rebuilds**. Codex stopped fighting and kept **512**.

### Udev congestion

- While filling thousands of network namespaces, **udev** (Linux device-event service) grew hundreds of workers (about 650–700) stuck in kernel sysfs access.
- Load averages were extreme (hundreds on the 5 and 15 minute windows at peaks).
- Codex capped udev workers (about **16**) via config because live runtime control timed out.
- Blocked udev workers later fell to low double digits (about 22). Firecracker count was driven to **0** before measuring.

### Netns pool (network namespace shelf)

- **Netns** = per-sandbox private network stack. The runner pre-builds a pool (target **2100**) so the measured create wave does not pay full networking setup cost mid-flight.
- Pool gauges showed steady climb (examples: 69 → 109 → … → 2100) with small `inflight` (often 4).
- Full pool (`ready=2100`, `inflight=0`) was reached at least once, then later rebuilds started again after runner restarts.

### “No online runner” / lost heartbeat

- Creates returned **HTTP 400**: region `vera` has no online linux-class runner. **400** means bad request / cannot fulfill, not **401** auth failure.
- `systemctl` showed `rlp-runner` **active**. Health curl returned `{"status":"ok"}`. Local process up does not guarantee API status.
- Wrapper / checks still showed `vera-1|lost` even with an active unit.
- API logs: heartbeats from the rebuilt-from-`660e6e3b` runner **omitted required** `capabilities.classes` and `capabilities.windows`. API rejected those heartbeats → runner stayed **lost**.

### Fix that restored online

- **Keep Python SDK at `660e6e3b`.**
- **Build runner from a newer separate checkout** that includes the current heartbeat contract.
- New runner build succeeded at commit **`33ba48051`**, with required capability fields and native privileged-command limiter.
- After that deploy, status became: **`vera-1|online`** (example timestamp `2026-10-14 01:24:17+00`) while netns pool was mid-refill (example **1078/2100**).
- Codex continued waiting for full pool + DB/API confirm before warmup and the measured 1k.

### Current status (as of last update in this chat)

- Socket pin work and create-ready wrapper path are in progress under Codex.
- Runner online again with the newer binary.
- Netns pool was still filling toward 2100 after the good runner deploy.
- Measured Sep 8–matching 1k result **not yet confirmed** in this log. Next expected steps: pool full → warmup / template → `TARGET=vera DISK_GB=1` create-ready 1000 → report `ready_wall_s` near 11 s → commit JSONL + status note.

---

## Quick glossary

- **Sandbox:** short-lived microVM (Firecracker) used for one unit of work.
- **Create-ready 1000:** start 1000 sandboxes and wait until a simple probe (`echo ready`) succeeds in each.
- **Wall clock (`ready_wall_s`):** time from start until the whole batch is ready.
- **Socket pin:** restrict runner and VMs to one CPU socket so the result matches the published single-socket HQ run.
- **Netns pool:** pre-built set of network namespaces for sandboxes.
- **Udev:** kernel/userspace device event handling. Can stampede when many network devices appear.
- **Heartbeat:** runner periodically tells the API it is alive. Missing fields ⇒ API marks runner lost.
- **Quiet progress:** runner sends fewer intermediate status events during create.
- **Sudo limiter:** cap on parallel privileged host commands so the machine does not fork-storm on `sudo`.

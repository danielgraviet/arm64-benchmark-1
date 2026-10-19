# EPYC 9575F create-ready debug log

**Host:** `root@173.201.45.75` (`hosted.redswitches.com`)  
**Chip:** AMD EPYC 9575F (64C / 128T)  
**Target:** `epyc9575` · API/toolbox `http://127.0.0.1:8088` / `:9000`  
**Date:** 2026-10-02  
**Goal:** Clean create-ready 1000 near historical ~32–37 s wall, then smoke + three clean create-ready 2000s.

**Recipe (unchanged):** `dtgraviet/vera-agent-benchmark:v3`, cpu `0.025`, mem `0.0625` GiB, disk `1`, probe `echo ready`, workers=`count`, `RLP_HTTP_MAX_CONNECTIONS=4096`, `ulimit -n 65536`.

**Historical baseline (same recipe, Sep 8 on `rs-vl-us-15`):**

| File | ok / fail | create_s p50 | create_s max |
|------|-----------|--------------|--------------|
| `results/zen5-jsonl/redswitches_create_ready_1000_20260908_*.jsonl` | 1000 / 0 | ~20–24 s | ~30–32 s |

Headline doc quotes Zen 5 create-ready 1000 at **37.4 ± 0.3 s**.

---

## Progress summary (where we are)

| Milestone | Status |
|-----------|--------|
| Cell identity + harness `epyc9575` target | Done |
| Eng `rlp-sdk` with `cpu_max` / fractional `mem_mib` | Done (reinstall needed after `uv` reverts to PyPI 0.3.2) |
| Smoke 8 clean (~0.3 s) | Done repeatedly |
| Clean 400 (p50 create ~3.9 s, wall ~40 s) | Done earlier today |
| **First clean create-ready 1000 (0 fails)** | **Done** — wall still ~166–180 s |
| Create-ready 1000 near ~32–37 s | **Not yet** |
| Three clean create-ready 2000s + JSONL commit | Not started |

**Best clean 1k so far**

- `daniel-focus-here/zen5-9575f-jsonl/epyc9575_create_ready_1000_20261002_220747.jsonl` — `READY_WALL_S=180.1` ok=1000 fail=0  
- `..._20261002_222218.jsonl` — `READY_WALL_S=166.3` ok=1000 fail=0, `template=hit` ×1000  

**Fix that unlocked clean 1k:** `RLP_SNAPSHOTS=1` (snapshot-resume / template path is **opt-in** and was unset).

---

## Issues encountered

### 1. Create pickup hard-capped at 60 s

**Symptom:**  
`create job not picked up by any runner within 60s (no matching capacity)`

**Facts:**
- Documented in `tickets/epyc9755-eng-updated-instructions.md` and `scripts/host/run_dense2k.sh`: `CREATE_MAX_QUEUE_SECS_CAP` clamps pickup; `RLP_CREATE_MAX_QUEUE_SECS=600` does nothing past ~60 s.
- Raising `RLP_JOB_QUEUE_TTL_VM_CREATE_SECS` to 300 also did not help this failure class.

**Implication:** With low `RLP_VM_CONCURRENCY`, jobs wait in queue >60 s and die even if the cell would eventually finish them.

---

### 2. `RLP_VM_CONCURRENCY` cliff (admission vs overload)

| CONC | Typical 1k outcome (pre-snapshots) |
|------|-------------------------------------|
| 64 | ~400 clean; 700/1000 mass `pickup60` |
| 192 | Fewer storms, still many `pickup60` when creates slow |
| 256 | Better ok-rate, still pickup + toolbox errors |
| 512 | Clears pickup cliff; shifts failures to ready/toolbox timeouts |

**Implication:** 64-core box needs high create admission to beat the 60 s cap, but high CONC overloads cold boots and stretches `toolbox_wait`.

---

### 3. CPU weight = 3 under cgroups (burstable fair-share)

**Symptom:** Dense creates with `cpu=0.025` → `cpu.weight ≈ round(cpu*100) = 3` → FC/toolbox starvation, self-cordon / deadlines.

**Attempts:**
- Binary weight-floor patch on `rlp-runner` (bak at `/usr/local/bin/rlp-runner.bak-pre-weightfloor`).
- Env `RLP_CPU_WEIGHT_FLOOR=100`.
- Userspace loop `/usr/local/bin/rlp-cpu-weight-floor.sh` rewriting `vm-*/cpu.weight`.

**Note:** Successful 9755 create knobs had **no** `RLP_CGROUP_ROOT` at all. Cgroups-on vs off alone did not restore historical 1k wall on this cell.

---

### 4. Root cause of wall time: `toolbox_wait` + `template=miss`

Runner `boot-phases` logs (pre-fix):

```text
template=miss ... toolbox_wait_ms≈165000 ... total_ms≈180000
```

Aggregation over thousands of boots: **100% `template=miss`**, `toolbox_wait` p50 tens of seconds to minutes under density. Cold path itself (scratch/fc_start/rootfs) was often fine; the guest toolbox readiness wait dominated.

Client `probe_s` stayed tiny (p50 ~4 ms) once the sandbox was ready — the time is in runner create/toolbox, not the `echo ready` probe.

---

### 5. `RLP_SNAPSHOTS` unset (primary config bug)

From `runner/internal/runner/runner.go`:

```go
// Snapshot-resume path: opt-in via RLP_SNAPSHOTS=1.
if r.cfg.SubnetCIDR != "" && envIsSet("RLP_SNAPSHOTS") {
    r.vmm.EnableSnapshots(...)
    r.initTemplatePolicy()
    if envIsSet("RLP_TEMPLATE_CAS") { r.initTemplateCAS() }
}
```

**Without `RLP_SNAPSHOTS=1`:**
- No template manager → every create is cold (`template=miss`).
- `RLP_TEMPLATE_BUILD_AFTER` / CAS knobs are inert.
- `/mnt/.../templates` and `scratch/snapshots` stay empty forever.

**After enabling + warm create:**
```text
template-policy configured build_after=1 ...
template-cas enabled dir=/mnt/nvme1/rlp/template-cas
template build starting ... mem_mib=512
template build ready
template published to cas
```

Early hits: `template=hit resume=1 total_ms≈54 toolbox_wait_ms≈4`.  
Under 512-wide waves, hit path still stretches (`toolbox_wait` p50 ~20–40 s) — remaining wall-time problem.

---

### 6. Second NVMe unused

**Layout when we arrived:**
- `nvme0n1p4` → `/` (also held `/mnt/data/rlp/...`)
- `nvme1n1` → raw, unformatted, unused

**Change made:**
- `mkfs.ext4` on `nvme1n1`, mount `/mnt/nvme1`, fstab entry.
- `RLP_LOCAL_SCRATCH=/mnt/nvme1/rlp/scratch`
- NFS/layers/kernel copied to `/mnt/nvme1/rlp/nfs00` and pointed env at it.
- Template CAS dir: `/mnt/nvme1/rlp/template-cas`

Scratch leftovers were large sparse files (~256 GiB apparent / ~1.1 GiB resident per VM). Must wipe between runs **without** deleting `scratch/snapshots/`.

---

### 7. Dirty cell / orphan Firecracker / stale cgroups

- Cleanup via paginated API often reported `live=0` while `pgrep firecracker` still showed orphans.
- Empty `vm-*` cgroups accumulated (1000+ dirs) until purged with `rmdir`.
- Runner restart refills netns pool to 2100 → load spike; need cool-down before measuring.
- AGENTS.md: prefer API/cleanup drain over blanket `killall -9 firecracker`; orphans after restart were force-killed when stuck.

---

### 8. Eng SDK overlay lost

`run_create_ready.sh` asserts `Resources.cpu_max`. Bare `uv sync` / env churn reverted to PyPI `rlp-sdk==0.3.2`.

**Fix:** `uv pip install -e /home/ubuntu/rlp/clients/python` at pin `660e6e3bd` + fractional `mem_mib` patch.  
`install_eng_rlp_sdk.sh` `git fetch` failed (no GitHub creds / dubious ownership); local checkout + `git -c safe.directory=...` worked.

---

### 9. Operational friction

| Issue | Detail |
|-------|--------|
| tmux as root | Flaky (`no server`); used `nohup` for long runs |
| Log tee permissions | `/tmp/zen5-create-ready-epyc9575-*.log` owned wrong → wrapper `END_EXIT=1` even when bench ok |
| Duplicate env keys | Repeated edits left duplicate `RLP_*` lines in `runner.env` (last wins, but messy) |
| SSH under load | Banner timeouts when load ≫200 after dense waves |

---

### 10. Knobs that looked promising but did not fix 1k wall alone

| Knob / change | Effect |
|---------------|--------|
| `RLP_CREATE_MAX_QUEUE_SECS=600` | Ignored past 60 s cap |
| `RLP_JOB_QUEUE_TTL_VM_CREATE_SECS=300` | Did not stop `pickup60` |
| Cgroups off (match 9755 bak) | Smoke/400 fine; 1k still slow/failing without snapshots |
| CPUWeight=1000 on api/proxy/runner | Helped control plane; not sufficient alone |
| Weight floor @100 | Stops weight=3 pathology; not enough for historical wall without templates |
| CONC=192 with templates | Faster toolbox p50, but `pickup60` returned (~210 fails) |

---

### 11. Remaining wall-time issue (open)

Even with **100% template hits** and **0 fails**:

| Metric | Clean 1k (snap512) |
|--------|---------------------|
| READY_WALL | ~166–180 s |
| create_s p50 | ~63–66 s |
| toolbox_wait p50 (hits) | ~20–40 s |
| Fast hits (start of wave) | total ~50 ms, toolbox ~4 ms |

**Hypothesis:** Under 512-wide resume waves, guest/proxy path saturates (also saw ~950 orphaned TCP). `rlp.slice/vms` defaulted to `cpu.weight=10000` vs runner `1000`, starving non-guest work; lowered vms to `100` and persisted via systemd `ExecStartPost` — **re-measure pending**.

Target still ~32–37 s historical wall.

---

## What works now (current cell config)

As of last edit on DUT `/etc/rlp/runner.env` (effective process env):

```text
RLP_SNAPSHOTS=1
RLP_TEMPLATE_BUILD_AFTER=1
RLP_TEMPLATE_BUILD_WINDOW_SEC=3600
RLP_TEMPLATE_CAS=1
RLP_TEMPLATE_CAS_DIR=/mnt/nvme1/rlp/template-cas
RLP_TEMPLATE_BUDGET_BYTES=214748364800
RLP_VM_CONCURRENCY=512
RLP_VM_MAXACK=2048
RLP_STOP_CONCURRENCY=512
RLP_LOCAL_SCRATCH=/mnt/nvme1/rlp/scratch
RLP_NFS_ROOT=/mnt/nvme1/rlp/nfs00
RLP_LAYERS_MOUNT=/mnt/nvme1/rlp/nfs00/layers
RLP_SYSTEM_DIR=/mnt/nvme1/rlp/nfs00/system
RLP_KERNEL=/mnt/nvme1/rlp/nfs00/kernel/vmlinux-6.8.12-rlp3
RLP_CGROUP_ROOT=/sys/fs/cgroup/rlp.slice/vms
RLP_CPU_WEIGHT_FLOOR=100
RLP_MAX_LIVE_VMS=3000
RLP_NETNS_POOL=2100
```

Also:
- `/mnt/nvme1` mounted (fstab), scratch + layers + CAS on nvme1.
- systemd drop-ins: `CPUWeight=1000` for `rlp-api` / `rlp-proxy` / `rlp-runner`; `ExecStartPost` to set `vms` weight 100 / runner 1000.
- Stock runner binary preferred over ad-hoc binary patches; weight floor via env + userspace rewriter.
- Template snapshot present under `/mnt/nvme1/rlp/scratch/snapshots/<hash>/` after warm 8.

---

## Experiment timeline (compressed)

1. **Baseline fail:** 1k ~196 s with mass failures; suspected snapshot/agent path, then weight=3 / cgroups.
2. **CONC sweeps:** 64 → clean 400 @30.9 s; 1k still `pickup60`. TTL bumps useless.
3. **CONC 256/512:** Pickup clears at 512; failures become ready/toolbox timeouts; wall ~190–200 s.
4. **Cgroups off:** Matches 9755 env shape; still not historical 1k.
5. **Boot-phases:** Dominated by `toolbox_wait` + `template=miss`.
6. **nvme1:** Formatted/mounted; scratch + nfs moved off root disk.
7. **Template knobs without `RLP_SNAPSHOTS`:** No builds (policy never inits).
8. **`RLP_SNAPSHOTS=1`:** Template builds in ~1 s after warm 8; **two clean 1k runs** (~180 s / ~166 s).
9. **CONC 192 + snaps:** Toolbox healthier, pickup fails return.
10. **vms cgroup weight 10000→100:** Applied; re-benchmark in flight / next.

---

## Operator checklist (before next 1k / 2k)

1. `tr '\0' '\n' < /proc/$(pidof rlp-runner)/environ | grep RLP_SNAPSHOTS` → must be `1`.
2. `ls /mnt/nvme1/rlp/scratch/snapshots` → at least one hash dir (warm with `run_create_ready.sh 8` if empty).
3. Drain: `UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target redswitches` (or `epyc9575`); confirm `pgrep firecracker` empty.
4. Wipe scratch **keeping snapshots:**  
   `find /mnt/nvme1/rlp/scratch -mindepth 1 -maxdepth 1 ! -name snapshots -print0 | xargs -0 rm -rf`
5. Purge empty `vm-*` cgroups under `/sys/fs/cgroup/rlp.slice/vms/`.
6. Wait for load cool after netns refill (load1 low, netns `ready≈2100`).
7. Confirm eng SDK: `UV_NO_SYNC=1 uv run python -c 'from rlp import Resources; assert "cpu_max" in Resources.__dataclass_fields__'`.
8. Run: `bash scripts/host/run_create_ready.sh 1000` (log under `/tmp/zen5-create-ready-*.log`).
9. Success criteria: `END_EXIT=0`, `failed=0`, prefer `READY_WALL_S` in the mid-30s; inspect `boot-phases` for `template=hit` and low `toolbox_wait_ms`.

---

## Artifacts

| Kind | Path |
|------|------|
| Latest clean 1k JSONL | `daniel-focus-here/zen5-9575f-jsonl/epyc9575_create_ready_1000_20261002_222218.jsonl` |
| Prior clean 1k | `..._20261002_220747.jsonl` |
| Historical Sep 8 | `results/zen5-jsonl/redswitches_create_ready_1000_20260908_*.jsonl` |
| 9755 clean 1k (p50 ~11 s) | `daniel-focus-here/zen5-9755-jsonl/epyc9755_create_ready_1000_*.jsonl` |
| Runner env on DUT | `/etc/rlp/runner.env` (+ `*.bak-*`) |
| Template docs (upstream) | `/home/ubuntu/rlp/internal-docs/workflows/runner/templates-and-pools.md` |
| Run logs on DUT | `/tmp/zen5-create-ready-1k-*.log` |

---

## Next steps

1. Finish measuring 1k with `vms` cgroup weight=100 (aim wall ≪166 s, still 0 fails).
2. If still slow: profile proxy/toolbox under resume wave (orphaned TCP, softnet, `clone_ms` breakdown); consider client-side create batching only if cell-side is saturated.
3. Smoke 8 → three clean create-ready **2000** with same snap+nvme knobs.
4. Commit JSONL under `daniel-focus-here/zen5-9575f-jsonl/` (one run per commit) and refresh any `zen5_graph_ready_2k` stub.
5. Persist a minimal “9575F create cell” env snippet in-repo so the next DUT bootstrap does not omit `RLP_SNAPSHOTS=1`.

---

## Resolution (2026-10-02 23:22 UTC): 1k at 35.6 s, 0 fails

Two host/cell config bugs, neither in runner.env. Apply with `bash scripts/host/tune_epyc9575_create.sh` (root).

1. **ARP neighbor table overflow.** `dmesg`: ~10k `neighbour: arp_cache: neighbor table overflow!`, saturating during every 1k wave. Kernel default `gc_thresh3=1024` is global across netns, so at ~1k VMs the runner could not reach resumed guests: `fc_start` ~30 ms but `toolbox_wait` ~100 s, and throughput stuck at ~5–6/s no matter the concurrency. Fix: `/etc/sysctl.d/99-rlp-neigh.conf` (thresh 8192/32768/65536). Result: 166 s → 86 s.
2. **16-vCPU guests.** `RLP_BURST_MAX_CPU` was unset, so the API default of 16.0 applied. The client sends no `cpu_max`, so every sandbox was a 16-vCPU Firecracker guest. During the wave, guest CPU was 87–96% of the host with a run queue of 2000–3500. Sep 8 used `RLP_BURST_MAX_CPU=1`. Fix: set it in `api.env` and restart `rlp-api`. Result: 86 s → 39.2 s / 35.6 s.

| JSONL (on DUT) | wall | p50 | p95 | ok/fail |
|---|---|---|---|---|
| `epyc9575_create_ready_1000_20261002_231136.jsonl` (ARP fix only) | 86.0 | 21.2 | 59.6 | 1000/0 |
| `epyc9575_create_ready_1000_20261002_232050.jsonl` (+ burst cpu 1) | 39.2 | 18.2 | 32.3 | 1000/0 |
| `epyc9575_create_ready_1000_20261002_232214.jsonl` (+ burst cpu 1) | 35.6 | 18.7 | 29.9 | 1000/0 |

Config at the time: `RLP_VM_CONCURRENCY=512`, `RLP_SNAPSHOTS=1` (1000/1000 template hits), weight-floor loop still running. Gotcha: running the wrapper as root over SSH needs `PATH=/home/ubuntu/.local/bin:$PATH`, otherwise `uv` is not found.

**How it was found**

- Fix 1: across every run, throughput stayed at ~4.5–6.7/s at concurrency 64, 128, 192, 256 and 512, with or without snapshots and cgroups. That pointed to one bottleneck, not CPU load. `dmesg` timestamps put the overflow messages inside every 1k run.
- Fix 2: after fix 1, `vmstat` during the wave showed `gu` (guest CPU) at 87–96% and `sy` (host kernel) at only 2–9%. Counting `fc_vcpu` threads per Firecracker PID gave 16, where 1 was expected. `api/src/state.rs` confirms `RLP_BURST_MAX_CPU` defaults to `16.0`.

**Before the 2k runs**

- At ~28 creates/s, 2k should take ~70 s of wall time. With 512 slots, the last creates wait ~53 s for pickup, close to the 60 s cap. Watch for `pickup60` errors.
- 9 orphaned 16-vCPU VMs (from the 22:31 run, unknown to the API) were still alive. Kill them before the 2k runs for a fully clean cell.
- The new JSONLs are still on the DUT only: commit and push them from the box.

**2k batch 1 (2026-10-02 23:26 UTC)**

Before the run: killed the 9 orphaned 16-vCPU Firecracker processes (the API showed 0 live), purged empty `vm-*` cgroups. Started from FC=0.

| JSONL (on DUT) | wall | p50 | p95 | ok/fail |
|---|---|---|---|---|
| `epyc9575_create_ready_2000_20261002_232612.jsonl` | 98.8 | 37.5 | 73.7 | 2000/0 |

No `pickup60` errors and no new ARP overflows. Throughput was 20.2/s, down from 28/s at 1k. A likely reason is the cost of holding already-ready guests: at the 1k hold, guest CPU was ~25% of the host. This has not been profiled yet.

**2k batch 2 (2026-10-02 23:31 UTC)**

| JSONL (on DUT) | wall | p50 | p95 | ok/fail |
|---|---|---|---|---|
| `epyc9575_create_ready_2000_20261002_233120.jsonl` | 151.3 | 39.0 | 74.7 | 2000/0 |

p50 and p95 match batch 1. The extra ~50 s of wall time comes from a tail: 44 creates landed at 145–150 s.

**What causes the 2k tail: the Firecracker socket wait gives up after 3 s and requeues the create.** The runner log shows `create retry: will redeliver ... clone fc sock: socket .../fc.sock not accepting within 3s`. Both batches have it: batch 1 had 547 retries across 441 VMs, batch 2 had 661 across 430. Nearly all of them fall in the peak minute. The 3 s timeout is hardcoded (`runner/internal/vm/template.go`, `waitForSocket(ctx, sock, 3*time.Second)`) with no env override. Fix options:
- **Platform:** make the timeout configurable or raise it (needs a runner rebuild).
- **Config:** start fewer Firecracker processes at once at peak (lower `RLP_VM_CONCURRENCY`). This risks pickup-60 s failures at 2k.

**2k batch 3 (2026-10-02 23:38 UTC)**

| JSONL (on DUT) | wall | p50 | p95 | ok/fail |
|---|---|---|---|---|
| `epyc9575_create_ready_2000_20261002_233826.jsonl` | 93.9 | 40.9 | 71.7 | 2000/0 |

524 `create retry` lines (the 3 s socket timeout), with no late tail this time.

**All three 2k runs:** 98.8 / 151.3 / 93.9 s wall, 6000/6000 ok, 0 fails. Batch 2's outlier wall comes from the 3 s socket-retry tail described above.

**2k batch 4 (2026-10-02 23:41 UTC)**

| JSONL (on DUT) | wall | p50 | p95 | ok/fail |
|---|---|---|---|---|
| `epyc9575_create_ready_2000_20261002_234110.jsonl` | 96.0 | 37.4 | 69.3 | 2000/0 |

595 `create retry` lines, with no late tail. It started ~1 min after batch 3 (load1 635 from teardown) and still landed in range. **Three of four 2k runs are at 93.9–98.8 s.** Batch 2 (151.3 s) is the socket-retry outlier.

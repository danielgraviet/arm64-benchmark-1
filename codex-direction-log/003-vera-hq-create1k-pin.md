# Direction: pin HQ Vera + create-ready 1000 ≈ 11 s wall

You are Codex on HQ Vera (`daytona`, clone `~/arm64-benchmark-1`). Axis SSH from Mac agents is break-glass only. Work on-box. Commit JSONL + short notes; `git push` so the Mac can pull.

## Goal

Reproduce Sep 8 HQ create-ready 1000:

| Metric | Target |
|---|---|
| ok / fail | 1000 / 0 |
| `ready_wall_s` | about **11 s** (Sep 8 clean was **10.7–10.8 s**) |
| create p50 | about **3.1–3.7 s** |
| create p95 / max | about **10.1–10.8 s** (not 20–80 s) |

Reference meta: `daniel-focus-here/vera-jsonl/vera_create_ready_1000_clean_20260908_122335.meta.json`

CTO’s new-env runs were ~8–10 s median ready and 20–83 s tails. That is **not** Sep 8. Fix the environment, then re-run until wall is ~11 s.

## Recipe (onsite HQ, not OCI)

- Image: `dtgraviet/vera-agent-benchmark:v3`
- cpu `0.025`, memory `0.0625` GiB, **disk `1.0` GiB** (HQ has disk; do **not** use OCI’s `0.015625`)
- probe: `echo ready`
- workers = count = 1000
- client on localhost `:8088` / toolbox `:9000`
- soft nofile ≥ 65536 (wrapper sets 65536; hard is already 1M)
- socket 0 pin: `rlp.slice` + VMs `0-87,176-263`, mems `0`

## Do this in order

Stay in `tmux` session `codex` (or attach). Do **not** kill long jobs by exiting the wrong session. Experiment runs go in their **own** tmux.

### 0) Pull and cwd

```bash
export PATH="$HOME/.local/bin:$PATH"
export UV_NO_SYNC=1
cd ~/arm64-benchmark-1
git pull
```

### 1) Idle + health

```bash
curl -fsS http://127.0.0.1:8088/health
systemctl is-active rlp-api rlp-proxy rlp-runner
pgrep -c firecracker || echo 0
uptime
```

If Firecrackers or harness leftovers exist, drain with the tracked cleanup for `--target vera`, then recheck until FC≈0 and load is boring. Do not measure on a hot box.

### 2) Cell parity (must pass)

```bash
bash scripts/host/check_vera_parity.sh
```

Fix fails before the 1k. Especially: `RLP_BURST_MAX_CPU=1`, `RLP_MIN_CPU<=0.025`, `RLP_MIN_MEM_MIB<=64`, `RLP_SNAPSHOTS=1`, high enough `RLP_VM_CONCURRENCY` / `RLP_MAX_LIVE_VMS` / `RLP_NETNS_POOL`, eng SDK with `region_routing` + `cpu_max`, `.env` localhost URLs + keys.

If parity cannot read `/etc/rlp/*.env`, use sudo. Do not reboot for kernel nags.

### 3) Pin socket 0 (currently unbound)

We confirmed `rlp.slice` cpuset was empty and `rlp.slice/vms` missing. Sep 8 was pinned.

```bash
bash tickets/vera-pin-single-socket.sh 0
```

Verify:

```bash
cat /sys/fs/cgroup/rlp.slice/cpuset.cpus   # want 0-87,176-263
cat /sys/fs/cgroup/rlp.slice/cpuset.mems   # want 0
# vms path if present:
cat /sys/fs/cgroup/rlp.slice/vms/cpuset.cpus 2>/dev/null || true
pid=$(pgrep -n rlp-runner); awk '/Cpus_allowed_list/ {print}' /proc/$pid/status
```

If pin fails (cpuset controller), fix using the script’s enable steps; do not invent a different CPU set.

### 4) Warm template path

Sep 8 ~11 s is **template resume**, not cold boot. The create-ready wrapper for `TARGET=vera` forces `RLP_TEMPLATE_BUILD_AFTER=1`, snapshots on, and a warmup so the template exists. Prefer the wrapper; do not skip warmup.

If the binary lacks `RLP_QUIET_PROGRESS`, the wrapper may patch/rebuild from `~/rlp/runner`. That is expected. Keep `UV_NO_SYNC=1` for the client. Eng SDK stays at `RLP_PIN=660e6e3b` if you must reinstall.

### 5) Run create-ready 1000 (HQ disk=1)

Own tmux so Codex can keep working:

```bash
tmux new-session -d -s vera-create1k \
  "bash -lc 'cd ~/arm64-benchmark-1 && export PATH=\"\$HOME/.local/bin:\$PATH\" UV_NO_SYNC=1 TARGET=vera DISK_GB=1 && bash scripts/host/run_create_ready.sh 1000; echo END_EXIT=\$?; exec bash'"
```

Watch:

```bash
tmux capture-pane -pt vera-create1k -S -80
```

When finished, find the new JSONL under `daniel-focus-here/vera-jsonl/` (or the wrapper’s OUT_DIR for `TARGET=vera`) and read the `summary` line:

- `ready_wall_s` ≈ 11
- `ok` = 1000, `failed` = 0
- `create_p50_s` ≈ 3–4, `create_p95_s` / `create_max_s` ≈ 10–11

### 6) Debug loop until ~11 s

If wall is still ~20–80 s or medians look like CTO’s new-env table, iterate. After each fix, drain FC, confirm pin still applied, re-run 1k.

Check in this order:

1. **Pin still held** after runner restarts (`cpuset.cpus` still `0-87,176-263`).
2. **Burst CPU = 1** live in `rlp-api` environ (`RLP_BURST_MAX_CPU=1`). Wrong burst (e.g. 16) destroys create walls (Zen5 lesson).
3. **Snapshots / template warm** — second+ run after warmup should be resume, not cold. Look for template/snapshot hits in runner logs if wall stays high.
4. **`RLP_EVENT_AUDIT=0`** on api (wrapper sets this).
5. **Quiet progress** — `grep -a -c RLP_QUIET_PROGRESS /usr/local/bin/rlp-runner` should be >0 after wrapper path; wrapper sets `RLP_QUIET_PROGRESS=1`.
6. **Sudo-storm limiter present** — `grep -a -c RLP_PRIV_EXEC_CONCURRENCY /usr/local/bin/rlp-runner` >0. Do not leave weight-floor loop running (`pgrep rlp-cpu-weight-floor` must be empty).
7. **Client knobs** — meta in JSONL should show disk `1.0`, nofile soft ≥65536, localhost target. For HQ 1k, wrapper may use a small HTTP poll pool (32) by design; do not blindly force 1024 unless you are explicitly A/B testing Sep 8 client shape. Prefer wall ≈11 over matching old HTTP=1024.
8. **Neigh / nofile** — `sysctl net.ipv4.neigh.default.gc_thresh3` ≥16384; recipe shell ulimit raised.
9. **Idle between runs** — FC=0, no leftover python harness, load boring.

Repeat 1k until three clean runs cluster near 11 s wall (or document the blocker with evidence).

### 7) Push results + status note

```bash
git add daniel-focus-here/vera-jsonl/<new files> codex-direction-log/
git commit -m "HQ Vera create-ready 1000 after socket0 pin (target ~11s wall)"
git push
```

Add `codex-direction-log/004-vera-create1k-status.md` with:

- pin verify lines
- parity pass/fail summary
- each 1k: JSONL path, `ready_wall_s`, ok/fail, p50/p95/max
- what you changed when a run missed ~11 s

## Hard rules

- On-box only. No laptop tunnel ladders.
- Do not reboot for apt kernel messages.
- Do not commit `.env` or Codex auth.
- Do not leave results only on the DUT.
- Prefer git-tracked wrappers (`run_create_ready.sh`, `vera-pin-single-socket.sh`, `check_vera_parity.sh`) over `/tmp` scripts.
- Keep Codex in `tmux` session `codex`; experiment in `vera-create1k`.

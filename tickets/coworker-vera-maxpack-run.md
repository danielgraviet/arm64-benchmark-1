# Coworker agent: run Vera agent max-pack ladder

**For:** an agent (or human) with SSH access to the NVIDIA Vera cell  
**Goal:** re-run the agent concurrency ladder past the old ~710 live-VM wall, **detached** so the operator can disconnect / close their laptop  
**Date:** 2026-08-26

---

## Context (read once)

- Repo on the Vera box: `~/arm64-benchmark-1`
- Workload: coding-agent `repo-agent-v3` (`--benchmark agent`)
- Image: `dtgraviet/vera-agent-benchmark:v3` (already on Hub; no rebuild needed)
- Matched burst flags: `--rlp-cpu 0.125 --rlp-cpu-max 1` (omit dedicated mode so packing can exceed ~348)
- Eng raised the live-VM / create-admission cap after creates above ~710 failed with:
  `create job not picked up by any runner within 60s (no matching capacity)`
- This run **probes whether that fix holds** through high concurrency

Background / error math: `tickets/eng-vera-live-vm-wall.md`

---

## Preconditions

1. SSH to the Vera node (on-node client — **not** a laptop tunnel). Hostname should be like `ipp8-d15-c2-vera-2`.
2. Confirm API is up: `curl -m 3 -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/` (401/200-ish is fine; timeout is not).
3. No other benchmark running: `pgrep -af 'uv run main.py' | grep -v pgrep || echo no-bench`
4. Working tree: `cd ~/arm64-benchmark-1` (pull latest if your teammate asked you to)

---

## Experiment recipe

| Knob | Value |
|------|--------|
| Levels | `704 880 1056 1408 1760 2112 2464 2784` |
| `--n` | `50` |
| `--seed` | `42` |
| `-E` | `8` |
| CPU | `--rlp-cpu 0.125 --rlp-cpu-max 1` |
| Mode | `--hold-then-exec` |
| Target | `--target vera` |
| Snapshot | `dtgraviet/vera-agent-benchmark:v3` |

- **704** = prior clean baseline (must stay 0 fails)  
- **880+** = past the old cliff (must not plateau at ~710 live)  
- **2784** ≈ theoretical pack at 0.125 on ~352 CPUs (may still hit a *new* soft limit — record it)

---

## Start detached (required — laptop-safe)

Prefer **tmux** so the run survives SSH disconnect.

```bash
cd ~/arm64-benchmark-1

pkill -f 'uv run main.py --benchmark agent' 2>/dev/null || true
tmux has-session -t vera-maxpack 2>/dev/null && tmux kill-session -t vera-maxpack

tmux new-session -d -s vera-maxpack bash -lc '
  cd ~/arm64-benchmark-1
  UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 704 880 1056 1408 1760 2112 2464 2784 \
    --n 50 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.125 --rlp-cpu-max 1 \
    2>&1 | tee /tmp/vera-agent-maxpack-n50-rerun.log
  echo END_EXIT=$? | tee -a /tmp/vera-agent-maxpack-n50-rerun.log
'

sleep 2
tmux ls
pgrep -af 'uv run main.py' | head -2
head -25 /tmp/vera-agent-maxpack-n50-rerun.log
```

**Pass start check:** log shows `output=.../rlp-vera-c0p125-max1/concurrency_*_n50.jsonl` and `rlp create started`. Then the operator may disconnect.

### Fallback if `tmux` is missing

```bash
cd ~/arm64-benchmark-1
nohup env UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 704 880 1056 1408 1760 2112 2464 2784 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1 \
  > /tmp/vera-agent-maxpack-n50-rerun.log 2>&1 &
disown
echo "PID=$!"
sleep 2
head -25 /tmp/vera-agent-maxpack-n50-rerun.log
```

---

## While running / after reconnect

```bash
# still alive?
pgrep -af 'uv run main.py' | grep -v pgrep || echo DONE

# summaries so far
grep '"concurrency"' /tmp/vera-agent-maxpack-n50-rerun.log | grep throughput

# attach live log (tmux)
tmux attach -t vera-maxpack
# detach without killing: Ctrl-b then d

# or
tail -f /tmp/vera-agent-maxpack-n50-rerun.log
```

JSONL path is printed at start of the log (`output=...`). Typical dir:

`~/arm64-benchmark-1/data/agent/rlp-vera-c0p125-max1/concurrency_<timestamp>_n50.jsonl`

---

## Success / failure criteria

For each completed summary line:

| Check | Good | Bad (old wall) |
|-------|------|----------------|
| `failures` | **0** (or near 0) | grows as `≈ c − 710` |
| `runs` | **`concurrency * 8`** | much less than `c * 8` |
| Error text | none | `create job not picked up by any runner within 60s` |
| `exit_code` on fails | — | **-1** create failures |

Quick live estimate if create fails dominate: `live ≈ concurrency − failures` should stay ≈ concurrency when fixed (not stuck near 710).

Also note `checksum_ok` / `END_EXIT` at the end of the log — separate from create capacity.

---

## Do not

- Do not run from a laptop through an SSH tunnel to Vera (skews packing / connection caps)
- Do not omit `--rlp-cpu-max 1` (falls back toward dedicated ~348 Class B wall)
- Do not leave the process attached to an interactive SSH session if the human needs to leave — use tmux/nohup as above
- Do not start a second overlapping `main.py` agent ladder on the same cell

---

## When finished — report back

Paste:

1. Path to the new JSONL  
2. Each level’s summary: `concurrency`, `runs`, `failures`, `throughput_per_sec`, `p50_duration_ms`, `create_wall_s`  
3. Whether 880+ cleared the old ~710 cliff  
4. `END_EXIT` from the log  
5. Any new ceiling (first level where fails climb again)

Optional: copy JSONL off-box for the benchmark owner (`danielgraviet` / arm64-benchmark-1).

# Phoenix agent max-pack ladder (match Vera m512)

**For:** operator with SSH to the **Phoenix cell API host** (`us-phoenix-1`)  
**Goal:** clean matched pair to `data/agent/rlp-vera-c0p125-max1-m512/concurrency_20260826_230252_n50.jsonl`  
**Date:** 2026-08-28

---

## Why rerun

Post-ARP-fix (Vedran `redswitches` branch): Phoenix networking bug caused mass create failures above ~880 on earlier laptop runs. Re-run the **same levels as Vera m512** so charts share one x-axis.

Laptop runs (`client_host: Daniels-MacBook-Air-5.local`) before ARP fix are **not usable** for Vera compare:

| File | Problem |
|------|---------|
| `concurrency_20260827_174723_n50.jsonl` | 704/880 OK (0 fails); 1056+ heavy fails; **1760–2784 all create failures** |
| `concurrency_20260827_165442_n50.jsonl` | Stopped mid-ladder; 1056+ corrupted |
| `isolated_c880_*`, `isolated_c1056_*` | 100% create failures |

Vera reference completed all levels on-node (`ipp8-d15-c2-vera-2`) with 0 fails through 1760 and partial fails only at 2112+.

**Run from the Phoenix cell**, same as Vera on-node requirement in `RUNBOOK.md`.

---

## Matched recipe (must match Vera exactly)

Pin against: `data/agent/rlp-vera-c0p125-max1-m512/concurrency_20260826_230252_n50.jsonl`

| Knob | Value |
|------|--------|
| Levels | `704 880 1056 1408 1760 2112 2464 2784` |
| `--n` | `50` |
| `--seed` | `42` |
| `-E` | `8` |
| CPU | `--rlp-cpu 0.125 --rlp-cpu-max 1` |
| Memory | `--rlp-memory 0.5` (512 MiB; SDK rounds via GiB) |
| Mode | `--hold-then-exec` |
| Target | `--target us-phoenix-1` |
| Snapshot | `dtgraviet/vera-agent-benchmark:v3` |
| Output dir | `data/agent/rlp-phoenix-c0p125-max1-m512/` |

Phoenix theoretical pack at 0.125 vCPU is ~**3,041** sandboxes (vs Vera ~2,784). Levels through 2784 should fit if live-VM admission allows.

---

## Preconditions

1. SSH to Phoenix cell API host (not laptop remote API).
2. Repo on box: `~/arm64-benchmark-1` (pull latest).
3. No other agent ladder: `pgrep -af 'uv run main.py' | grep -v pgrep || echo no-bench`
4. Env: Phoenix RLP URLs point at **local/LAN** cell endpoints if available (same pattern as Vera `rlp-control`).
5. Clear leftover sandboxes (API list is paginated; use the cleanup script):

```bash
uv run python scripts/phoenix_rlp_cleanup_sandboxes.py
# preview only:
uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --dry-run
```

---

## Start detached (tmux)

```bash
cd ~/arm64-benchmark-1

pkill -f 'uv run main.py --benchmark agent' 2>/dev/null || true
tmux has-session -t phoenix-maxpack 2>/dev/null && tmux kill-session -t phoenix-maxpack

tmux new-session -d -s phoenix-maxpack bash -lc '
  cd ~/arm64-benchmark-1
  UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 704 880 1056 1408 1760 2112 2464 2784 \
    --n 50 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5 \
    --output data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_$(date -u +%Y%m%d_%H%M%S)_n50.jsonl \
    2>&1 | tee /tmp/phoenix-agent-maxpack-n50.log
  echo END_EXIT=$? | tee -a /tmp/phoenix-agent-maxpack-n50.log
'

sleep 2
tmux ls
pgrep -af 'uv run main.py' | head -2
head -25 /tmp/phoenix-agent-maxpack-n50.log
```

**Pass start check:** log shows `output=.../rlp-phoenix-c0p125-max1-m512/concurrency_*_n50.jsonl` and `rlp create started`.

---

## Optional: on-node redo of 1 GiB ladder (1–704)

Only if you also need a clean on-node match to Vera `concurrency_20260826_005637_n50.jsonl` (Phoenix laptop file has 1 fail at 704):

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 1 8 22 44 88 132 176 264 352 528 704 \
  --n 50 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.125 --rlp-cpu-max 1 \
  --output data/agent/rlp-phoenix-c0p125-max1/concurrency_$(date -u +%Y%m%d_%H%M%S)_n50.jsonl
```

Run **after** max-pack completes, or on a second Phoenix runner if capacity allows. Do not overlap two agent ladders on one cell.

---

## Success criteria (per level)

| Check | Good |
|-------|------|
| `failures` | **0** (Phoenix 704 reference: 0 fails) |
| `runs` | **`concurrency × 8`** |
| `throughput_per_sec` | nonzero exec throughput |
| Error | no `create job not picked up by any runner within 60s` mass failures |

Compare Vera m512 summaries at same levels for density story (expect Zen 5 ~10 jobs/s plateau vs Vera ~23).

---

## When finished — report

1. JSONL path  
2. Per-level: `concurrency`, `runs`, `failures`, `throughput_per_sec`, `p50_duration_ms`, `create_wall_s`  
3. `END_EXIT` from log  
4. First level where fails climb (if any)

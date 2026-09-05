# Eng ticket: Phoenix agent ladder — match Vera concurrency levels

**For:** Vedran  
**From:** Daniel  
**Goal:** One clean Phoenix JSONL at the **exact same concurrency levels as Vera** so we can plot Vera vs Zen5 on a shared x-axis (marketing / NVIDIA brief charts).  
**Date:** 2026-08-28

---

## Context

We have a complete Vera agent max-pack ladder:

`data/agent/rlp-vera-c0p125-max1-m512/concurrency_20260826_230252_n50.jsonl`

Charts merge Vera **1 GiB base** (`…005637_n50.jsonl`, levels 1–704) with that **512 MiB** file (levels 704–2784). Phoenix needs the same m512 ladder so both series share these **18 x-axis points**:

`1, 8, 22, 44, 88, 132, 176, 264, 352, 528, 704, 880, 1056, 1408, 1760, 2112, 2464, 2784`

Phoenix **1 GiB through 704** already exists (`rlp-phoenix-c0p125-max1/concurrency_20260826_012143_n50.jsonl`). **This ticket is only the m512 max-pack extension** at Vera’s levels.

### What we already know

| Run | Client | Ladder | Result |
|-----|--------|--------|--------|
| Vera m512 reference | on-node Vera | `704 … 2784` | 0 fails through **1760**; partial at 2112+ (live-VM cap) |
| Phoenix `221130` (your ARP-fix run) | on-node Phoenix | `128, 256, 512, 1013, … 3041` | **0 fails through 3041** — proves post-ARP Phoenix packs |
| Phoenix `153136` (Daniel laptop) | laptop → remote API | `704 … 2784` (matched) | OK through **1056**; **1408+** mass `no matching capacity` create failures |

Laptop / remote API is not usable above ~1056 on the matched ladder. Need **on-cell Phoenix API host**, same as your `221130` run.

---

## Run spec (must match Vera m512 exactly)

Pin against Vera reference meta:

```text
data/agent/rlp-vera-c0p125-max1-m512/concurrency_20260826_230252_n50.jsonl
```

| Knob | Value |
|------|--------|
| **Levels** | `704 880 1056 1408 1760 2112 2464 2784` |
| `--n` | `50` |
| `--seed` | `42` |
| `-E` | `8` |
| CPU | `--rlp-cpu 0.125 --rlp-cpu-max 1` |
| Memory | `--rlp-memory 0.5` (512 MiB) |
| Mode | `--hold-then-exec` |
| Target | `--target us-phoenix-1` |
| Snapshot | `dtgraviet/vera-agent-benchmark:v3` |
| Output dir | `data/agent/rlp-phoenix-c0p125-max1-m512/` |

Expected episodes per level: **`concurrency × 8`** (e.g. 704 → 5632 runs).

---

## Preconditions

1. **SSH to Phoenix cell API host** (`us-phoenix-1`), not a laptop hitting `api.us-phoenix-1.rlp.trydaytona.com` remotely.
2. Repo on box with latest harness (your `redswitches` branch or `main` after merge).
3. No overlapping agent ladder: `pgrep -af 'uv run main.py' | grep agent || echo ok`
4. Clear leftover Phoenix sandboxes (list is paginated):

```bash
cd ~/arm64-benchmark-1
uv run python scripts/phoenix_rlp_cleanup_sandboxes.py
```

---

## Command (tmux detached)

```bash
cd ~/arm64-benchmark-1

pkill -f 'uv run main.py --benchmark agent' 2>/dev/null || true
tmux has-session -t phoenix-vera-ladder 2>/dev/null && tmux kill-session -t phoenix-vera-ladder

tmux new-session -d -s phoenix-vera-ladder bash -lc '
  cd ~/arm64-benchmark-1
  UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
    --snapshot dtgraviet/vera-agent-benchmark:v3 \
    --levels 704 880 1056 1408 1760 2112 2464 2784 \
    --n 50 --seed 42 -E 8 --hold-then-exec \
    --rlp-cpu 0.125 --rlp-cpu-max 1 --rlp-memory 0.5 \
    --output data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_$(date -u +%Y%m%d_%H%M%S)_n50.jsonl \
    2>&1 | tee /tmp/phoenix-vera-matched-ladder.log
  echo END_EXIT=$? | tee -a /tmp/phoenix-vera-matched-ladder.log
'

sleep 2
tmux ls
head -25 /tmp/phoenix-vera-matched-ladder.log
```

**Start check:** log shows `output=.../rlp-phoenix-c0p125-max1-m512/concurrency_*_n50.jsonl`, `client_host` is the Phoenix cell (not a Mac hostname), and `rlp create started`.

Monitor:

```bash
tail -f /tmp/phoenix-vera-matched-ladder.log
grep '"type":"summary"' data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_*_n50.jsonl | tail -8
```

---

## Success criteria (per level)

| Check | Good | Bad |
|-------|------|-----|
| `failures` | **0** (or Vera-like small partial only at top) | Mass failures |
| `runs` | **`concurrency × 8`** | `runs` ≈ `concurrency` with `exec_wall_s = 0` |
| `throughput_per_sec` | ~**18–20 /s** (Zen5) | **0** with full concurrency |
| Error strings | none | `create job not picked up by any runner within 60s (no matching capacity)` |

Reference Vera throughput at same levels: ~**22–23 jobs/s**.

---

## When finished — send Daniel

1. **JSONL path** on the Phoenix host (full path).
2. **Delivery** (pick one):
   - Push file to git branch (e.g. `redswitches` or a short-lived branch), **or**
   - `uv run scripts/upload_data_s3.py --bucket …` if S3 is easier, **or**
   - SCP / shared path — whatever is normal for eng → Daniel handoff.
3. Paste this summary table (from JSONL summaries):

```bash
grep '"type":"summary"' data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_<YOUR_STAMP>_n50.jsonl \
  | python3 -c "import sys,json; [print(json.loads(l)) for l in sys.stdin]"
```

4. `END_EXIT` from `/tmp/phoenix-vera-matched-ladder.log`
5. First concurrency level where `failures` climb (if any)

Daniel will pin the file in `scripts/nvidia_brief_agent_charts.py` (`MAXPACK_ZEN5`) and regenerate:

```bash
uv run python scripts/nvidia_brief_agent_charts.py
```

Output charts: `eda_output/nvidia-brief-agent-zen5-maxpack/` (Vera unchanged; Zen5 aligned through 2784).

---

## Do not use for this chart

These Phoenix m512 files have the **wrong ladder** or **laptop create failures** — keep for debugging only:

- `concurrency_20260828_153136_n50.jsonl` — matched levels but laptop; 1408+ 100% capacity fails
- `concurrency_20260828_131148_n50.jsonl` — partial ladder; ARP-era failures above 880
- `concurrency_20260827_174723_n50.jsonl` — laptop; 1760+ all fails
- `rlp-phoenix-c0p125-max1/concurrency_20260827_221130_n50.jsonl` — good ARP-fix data but levels `1013, 1520, …` not Vera’s `880, 1056, …`

# Agent coding-agent v3 ladder (Vera vs Zen 5)

## Workload

- Task: `repo-agent-v3` (default in `workload.agent` / `AGENT` harness spec)
- Loop: seed broken package → multi-file search → AST → oracle patches → heavy pytest
- Image: `dtgraviet/vera-agent-benchmark:v3` (multi-arch amd64+arm64)
- JSON contract: `task`, `iterations`, `duration_ms`, `checksum`

## Matched pair (eng — use this for 352/528/704)

**Do not compare `--rlp-cpu 1` past ~348 on Vera.**

| Cell | `--rlp-cpu 1` ceiling (reserve_pct=99) | `--rlp-cpu 0.125` ceiling |
|------|----------------------------------------|---------------------------|
| Vera (352 total CPU) | **~348** sandboxes — **352 rung fails** | **~2,784** |
| Phoenix (~380/runner) | ~381 | **~3,041** |

Class B (`no matching capacity`) at `--rlp-cpu 1` is **correct backpressure**, not a bug.
Raising `reserve_pct` to 100 only buys 352 vs 348 on Vera — still short at 528/704.

**Matched recipe:** both chips at **`--rlp-cpu 0.125`** (no dedicated 1-vCPU reservation).
Phoenix reference: clean **`rlp-phoenix-c0p125`** ladder (0 failures through 704) after ARP sysctl fix.

```bash
SNAP=dtgraviet/vera-agent-benchmark:v3
N=<calibrate Vera c=1 to 6–10s — see below>
LEVELS="1 8 22 44 88 132 176 264 352 528 704"
FLAGS="--levels $LEVELS --n $N --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.125"

# Vera (on-node only)
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot $SNAP $FLAGS
# → data/agent/rlp-vera-c0p125/

# Phoenix (on-cell client)
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot $SNAP $FLAGS
# → data/agent/rlp-phoenix-c0p125/
```

Optional burst caps (`--rlp-cpu-max 1`, memory/disk) go in **`rlp-vera-c0p125-max1`** — separate series; use only if eng asks. Plain **`0.125`** matches tonight's Phoenix ladder.

## Calibrate `--n` (6–10 s idle at c=1)

| Chip | Measured at `--n 30` | Target `--n` |
|------|----------------------|--------------|
| Zen 5 (c0p125 or c=1) | ~8 s | **30** |
| Vera | **~3.1 s** at n=30 — too light | **bump** (try 60→80 on-node smoke) |

Same `(n, seed)` → same checksum on both chips after calibration.

**Smoke before full ladder:**

```bash
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot dtgraviet/vera-agent-benchmark:v3 \
  --levels 1 --n <N> --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.125
```

## Legacy: dedicated 1 vCPU (`--rlp-cpu 1`)

Valid for **chip duration story through ≤264** where both fit under ceiling.
Not valid for **528/704** compare — Vera hits 348 cap, Phoenix ARP/Class B issues.

- Zen 5: `data/agent/rlp-phoenix/concurrency_20260825_191628_n30.jsonl`
- Vera: `data/agent/rlp-vera/concurrency_20260825_211103_n30.jsonl`

## Charts

Lead: **`duration_vs_concurrency`** and **`chip_speed_vs_concurrency`** (≤264 or 0-fail region).
Pair series: `rlp-phoenix-c0p125` vs `rlp-vera-c0p125`.

```bash
uv run python eda.py --benchmark agent --include rlp-phoenix-c0p125 rlp-vera-c0p125
```

Add failure-rate panel for 352+; do not treat raw tput at 704 as chip scaling (live-cap + fail rows).

## Status (2026-08-25)

- Dedicated `--rlp-cpu 1` v3 ladders done (Zen5 + Vera) — use for duration through ~264 only
- Phoenix **c0p125** clean through 704 (eng, post-ARP fix) — pair target
- Vera **c0p125** v3: **pending** — calibrate `n` then full ladder on-node
- Cancelled: `rlp-vera-c0p125-max1/concurrency_20260825_222112_n30.jsonl` (incomplete)

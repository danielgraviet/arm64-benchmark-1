# Agent coding-agent v3 ladder (Vera vs Zen 5)

## Workload

- Task: `repo-agent-v3` (default in `workload.agent` / `AGENT` harness spec)
- Loop: seed broken package → multi-file search → AST → oracle patches → heavy pytest
- No SQL as a cost center (legacy `--task repo-agent-v2` still available)
- Image: `dtgraviet/vera-agent-benchmark:v3` (also tagged `:latest`; multi-arch amd64+arm64)
- JSON contract unchanged: `task`, `iterations`, `duration_ms`, `checksum`

## Calibrated `--n`

| Host | Target idle (c=1 p50 `duration_ms`) | `--n` |
|------|--------------------------------------|-------|
| Zen 5 / Phoenix (measured) | ~8.2 s | **30** |
| Local Mac (proxy) | heavier at same `n` — do not use Mac `n` on chip | — |
| Vera | **TBD when cell reachable** — start **30**, trim/bump to 6–10 s | **30** |

Always re-check Vera c=1 before trusting a dual-chip chart.

## Recipe (same flags both chips)

Prefer `:v3` so cells do not stick on a stale `:latest` digest.

```bash
SNAP=dtgraviet/vera-agent-benchmark:v3
N=30

# Smoke c=1
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot $SNAP --levels 1 --n $N --seed 42 -E 8 --hold-then-exec --rlp-cpu 1

# Vera (requires on-node or tunnel; do not drive c≥88 via laptop tunnel)
UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot $SNAP --levels 1 --n $N --seed 42 -E 8 --hold-then-exec --rlp-cpu 1
```

Checksum gate: same `(n,seed)` → same `checksum` on Vera and Zen 5.

```bash
LEVELS="1 8 22 44 88 132 176 264 352 528 704"

UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target us-phoenix-1 \
  --snapshot $SNAP --levels $LEVELS --n $N --seed 42 -E 8 --hold-then-exec --rlp-cpu 1

UV_NO_SYNC=1 uv run main.py --benchmark agent --runner rlp --target vera \
  --snapshot $SNAP --levels $LEVELS --n $N --seed 42 -E 8 --hold-then-exec --rlp-cpu 1
```

## Validation gates (before marketing)

| Gate | Pass |
|------|------|
| Checksum | Identical digests both chips at `(30, 42)` |
| Chip idle | Vera p50 `duration_ms` clearly below Zen 5 at c=1 and through 0-fail levels |
| SMT story | Through 264–352, Vera tput ≥ Zen 5 with a **visible** gap |
| Overload | 528/704 may fail; prefer Vera plateau vs Zen 5 drop — if cliff is toolbox/live-cap, report fails, do not hang-cap one chip |
| Fairness | Same image digest family, same flags, dedicated 1 vCPU, hold-then-exec, uncapped tput (= completed / measured exec wall) |

## EDA

```bash
uv run python eda.py --benchmark agent --include rlp-phoenix rlp-vera
```

Lead slides: **duration** + **tput through SMT**; annotate 352+ if live-cap / toolbox dominates.

## Fairness notes (slides)

- Story is single cordoned box + SMT (176 physical → 352 logical on Vera); 704 is past-SMT pressure, not “SMT saturates at 700.”
- Throughput definition is identical on both chips (no asymmetric hang wall).
- Heavier coding loop improves per-core/SMT signal; remaining 352+ cliffs can still be platform (toolbox timeouts / live VM cap)—call that out rather than retuning the workload to fake a soft Zen 5 curve.

## Status (2026-08-25)

- Zen 5 full ladder done: `data/agent/rlp-phoenix/concurrency_20260825_191628_n30.jsonl` (`--n 30`, `:v3`)
  - 0 fails through **264**; **352** ~66% Daytona toolbox dial timeouts; 528/704 also noisy
- Vera ladder: blocked (no cell access); re-run when on-node / tunnel is up before dual-chip EDA

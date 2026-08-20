# Plan: Terminal-Bench–style evals benchmark

**Status:** Phase 1 `evals-tb-style-v3` (ladder = **log-surgery** only); Phase 2 wired (`--benchmark tbench --runner harbor`)  
**Date:** 2026-08-12  
**Related:** GTC Vera story, Daytona + Terminal-Bench / Harbor  

---

## Goal / claim (locked wording)

**Phase 1 say:** On Vera, Daytona finishes the same Terminal-Bench–*style* **log-surgery** trial faster / at higher concurrency (trials/sec, p99 wall), with stable in-sandbox verify time (`duration_ms`).

**Phase 2 say:** Harbor Terminal-Bench **oracle** pack finishes sooner / denser on Vera (wall time-to-finish at fixed concurrency).

**Do not say:** Terminal-Bench *leaderboard scores* are higher on Vera (that is model/agent quality).

---

## Phase 1 — in-repo (v3)

No hash-loop padding. Tasks are TB-shaped (setup → oracle → verify, subprocess). Image installs `gcc` + `libc6-dev`.

| Piece | Location |
| --- | --- |
| Tasks | Ladder = **log-surgery** only (`evals/tasks/log_surgery.py`). Other task modules remain in-tree unused. |
| Runner / CLI | `evals/runner.py`, `evals/agent.py` (`evals-tb-style-v3`, default `--n 1`) |
| Harness | `EVALS` in `harness/benchmarks.py` (`apt_packages` gcc/libc6-dev) |
| Image | `Dockerfile.evals` → `vera-evals-benchmark` |
| Tests | `tests/test_evals.py` |

### Sizing intent

- **One sandbox = log-surgery** (same task at every `--levels` worker). `--n` is unused.
- No per-job seed rotation; one checksum per wave is `checksum_ok`.
- **`duration_ms`**: oracle + verify only; use `-E 8` so create tax is not the chip story.
- Deterministic oracle, no LLM, no SHA-256 padding.
- Density matrix still `levels → 88`, `-E 1`.

### Density matrix (Chart B sibling)

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
uv run main.py --benchmark evals --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
```

Concurrency = `--levels`. Always `-E 1` for density.

Chip pack (one task per sandbox, warm reuse):

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 88 --n 1 --seed 42 -E 8
```

Headline: *“TB-style log-surgery trials: X/sec on Vera vs control.”*

Rebuild snapshot after task changes:

```bash
uv run scripts/build_daytona_snapshot.py --benchmark evals
```

---

## Phase 2 — real Harbor Terminal-Bench oracle (`main.py`)

**Why not `--runner docker --benchmark tbench`?**  
`--benchmark` is an in-sandbox workload image; `--runner docker` does `docker run <our-image>`. Real Terminal-Bench is owned by **Harbor** (dataset + oracle + verify + its own `-n` concurrency). Use `--runner harbor` instead. Phase 1 `--benchmark evals` remains the harness-native TB-*style* path.

| Piece | Location |
| --- | --- |
| Spec | `TBENCH` in `harness/benchmarks.py` |
| Runner | `harness/runners/harbor.py` — one `harbor run` per `--levels` value |
| CLI | `uv run main.py --benchmark tbench --runner harbor …` |
| Tests | `tests/test_harbor_tbench.py` |

### CLI mapping

| Our flag | Harbor |
| --- | --- |
| `--levels L` | one job with `-n L` (Harbor concurrency; **no** ThreadPool of L) |
| `--n N` | `-l N` task limit (`0` = no limit / full pack) |
| `--target` | `DAYTONA_TARGET` env (Vera region flag TBD — do not invent Harbor CLI flags) |

Frozen defaults: `-d terminal-bench/terminal-bench-2 -a oracle --env daytona`.

### Install + commands

```bash
uv tool install 'harbor[daytona]'
export DAYTONA_API_KEY=…
```

```bash
# Smoke: 5 tasks, Harbor concurrency 5
uv run main.py --benchmark tbench --runner harbor --levels 5 --n 5
```

```bash
# Control pack at concurrency 32 (no task limit)
uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0
```

```bash
# Vera pair (same dataset/agent/concurrency; only region differs)
uv run main.py --benchmark tbench --runner harbor --levels 32 --n 0 --target <vera-region>
```

Frozen defaults (smoke-pinned **2026-08-12**):

- Harbor CLI: **0.19.0** (`uv tool install 'harbor[daytona]'`)
- Dataset: `terminal-bench/terminal-bench-2`
- Agent: `oracle`
- Env: `daytona` (`--env` / `-e`)
- Control smoke: `--levels 5 --n 5` → wall ~83s, `n_completed_trials=5`, mean reward **0.8** (1/5 oracle task failed: `build-pov-ray`). Treat mean reward as diagnostic; primary metric remains **wall time-to-finish**. Infra red = Harbor non-zero exit or `n_errored_trials > 0`.

Jobs land under `data/tbench/harbor/jobs/<job-name>/` (plus JSONL summaries).

**Status:** Control smoke green; Vera blocked on region targeting confirmation.

---

## Messaging guardrails

- Phase 1 = “Terminal-Bench–**style** evals” (`--benchmark evals`)
- Phase 2 = “Harbor Terminal-Bench **oracle** pack on Daytona×Vera” (`--benchmark tbench --runner harbor`)
- Never claim TB leaderboard % from Vera CPU alone

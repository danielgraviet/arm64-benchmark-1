# Plan: Terminal-Bench–style evals benchmark

**Status:** Phase 1 hardened (`evals-tb-style-v2`)  
**Date:** 2026-08-12  
**Related:** GTC Vera story, Daytona + Terminal-Bench / Harbor  

---

## Goal / claim (locked wording)

**Say:** On Vera, Daytona finishes the same Terminal-Bench–*style* eval pack faster / at higher concurrency (trials/sec, p99 wall), with stable in-sandbox verify time (`duration_ms`).

**Do not say:** Terminal-Bench *leaderboard scores* are higher on Vera (that is model/agent quality).

---

## Phase 1 — in-repo (v2 hardened)

| Piece | Location |
| --- | --- |
| Tasks | `evals/tasks/` — multi-file pytest fix, 120k-line log surgery, hash fingerprint build, permissions+CPU payload |
| Runner / CLI | `evals/runner.py`, `evals/agent.py` (`evals-tb-style-v2`, default `--n 1`) |
| Harness | `EVALS` in `harness/benchmarks.py` |
| Image | `Dockerfile.evals` → `vera-evals-benchmark` |
| Tests | `tests/test_evals.py` |

### Sizing intent

- **`--n 1`**: one sandbox ≈ one TB-style task (create tax paid once per trial).
- **`duration_ms`**: multi-second in-sandbox work (oracle + verify), large share of wall at `c=1`.
- Deterministic oracle (agent-shaped multi-step path), no LLM.
- Density matrix still `levels → 88`, `-E 1`.

### Density matrix (Chart B sibling)

```bash
uv run main.py --benchmark evals --runner daytona --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
uv run main.py --benchmark evals --runner rlp --target <vera-region> --levels 1 8 22 44 88 --n 1 --seed 42 -E 1
```

`--n` = tasks per trial; concurrency = `--levels`. Always `-E 1` for density.

Headline: *“TB-style eval trials: X/sec on Vera vs control.”*

Rebuild snapshot after task changes:

```bash
uv run scripts/build_daytona_snapshot.py --benchmark evals
```

---

## Phase 2 — real Harbor Terminal-Bench subset (logo, when Vera is live)

1. `uv tool install 'harbor[daytona]'` (or current Harbor install docs)  
2. Freeze dataset tag + concurrency; only change region:

```bash
export DAYTONA_API_KEY=…
# Control (default Daytona)
harbor run -d terminal-bench/terminal-bench-2 -a oracle --env daytona -n 32

# Vera region — document exact Harbor/Daytona target flag once the region exists
harbor run -d terminal-bench/terminal-bench-2 -a oracle --env daytona -n 32
```

3. Report **wall time to finish** + **achieved concurrency**, not accuracy (oracle should pass).  
4. Leaderboard submission needs `-k 5` etc. — optional later; not required for GTC infra slide.

---

## Messaging guardrails

- Phase 1 = “Terminal-Bench–**style** evals”  
- Phase 2 = “Harbor Terminal-Bench **oracle** pack on Daytona×Vera”  
- Never claim TB leaderboard % from Vera CPU alone  

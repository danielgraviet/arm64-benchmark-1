# Design Log

## 2026-08-06 — Target repo for simulated agent workload

**Daniel's approach:** Use one repo, vendored into the image, that covers the full
agent action loop — context gathering (grep/ls/read), a deterministic code edit,
running existing tests, and a SQLite query step — rather than splitting these
across multiple repos. Rationale: this mirrors what a real agent session actually
does (one repo, mixed actions) and represents a very common agent workflow.

**Critique:**
- Right: single repo = single vendored snapshot, single checksum surface, more
  faithful to real single-session agent behavior than a multi-repo split.
- Missed: SQLite usage must be intrinsic to the repo (not bolted on), or it reads
  as synthetic. Determinism requires pinning PYTHONHASHSEED, avoiding
  time/randomness-dependent tests, vendoring an exact frozen commit as source
  (no runtime pip install), and running only a fixed offline-safe subset of the
  test suite, not the full suite.
- Breaks at scale: if the workload writes to a shared repo path or fixed SQLite
  file, concurrent containers (tested at 1→176) will collide on file locks. Each
  run needs an isolated tmp copy of the repo and a throwaway .db file.

**Decision:** Vendor `sqlite-utils` (Simon Willison) as the single target repo.
Its core purpose is SQLite querying/manipulation, so the SQLite step is native
rather than artificial. Pure Python + stdlib sqlite3 (no compiled extensions,
so no ARM64/AMD64 drift risk), pytest suite runs fully offline, and it's sized
appropriately (a few thousand lines) for grep/AST/file-traversal to be
meaningful CPU work without dominating run time. Considered `attrs` (Daniel's
original example) but rejected it — no natural SQLite angle, would require
artificially wedging in queries.

**Next steps:** vendor a pinned commit of sqlite-utils into the repo, select a
fixed test subset, define the scripted deterministic code edit, and design the
isolated tmp workspace + throwaway db path for concurrent runs.

## 2026-08-06 — Pipeline shape: fixed order, one-shot per container

**Daniel's approach:** Use a fixed (non-randomized) pipeline of agent-style
tasks — search, AST parsing, code edits, SQL queries, test execution — to
mirror a real coding agent session, not a randomized-but-seeded order.
`--n` should not drive repeats of the pipeline within a single container:
repeating would require a redo/reset mechanism to guarantee identical repo
state each iteration, adding complexity with no realism payoff, since real
agent sandboxes are used once and discarded, never reset and rerun in place.
Daniel initially proposed `--n` control concurrency (how many containers run
at once) directly.

**Critique:**
- Right: one-shot pipeline per container matches real throwaway-sandbox
  usage and fully eliminates the reset/redo problem — there is no second
  iteration to keep consistent with the first.
- Conflict: the README already defines `--n` as "number of workload
  iterations" *inside* one container, and separately defines concurrency as
  strictly external — "Concurrency should be controlled outside the
  container. Each container should execute one independent benchmark run,"
  with an external runner launching multiple parallel `docker run`
  invocations at levels 1/8/22/44/88/176. A single container has no
  mechanism to control how many sibling containers exist, so `--n` cannot
  mean concurrency without breaking that contract.

**Decision:** Pipeline runs exactly once per container (no internal repeat
loop). Concurrency stays exactly where the README already puts it: an
external runner launching N parallel containers, unrelated to `--n`.
Repurpose `--n` to scale the amount of work inside the single one-shot run
(e.g. files touched by search/AST steps, size of SQL dataset) rather than
looping the whole pipeline — open question, pending Daniel's call on exactly
what `--n` scales.

**Next steps:** decide what `--n` scales inside the one-shot pipeline, then
pin the exact fixed task sequence (search pattern, AST target, edit target,
SQL query) and checksum composition across all task outputs.

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

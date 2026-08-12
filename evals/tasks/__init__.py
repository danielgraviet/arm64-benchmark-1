"""Task registry for TB-style eval trials."""

from __future__ import annotations

from evals.tasks import build_and_run, fix_failing_tests, log_surgery, permissions_path

# Stable order — seed picks a rotation start; --n is how many tasks per trial.
TASKS: list[tuple[str, object]] = [
    ("fix-failing-tests", fix_failing_tests),
    ("log-surgery", log_surgery),
    ("build-and-run", build_and_run),
    ("permissions-path", permissions_path),
]

TASK_IDS = [t[0] for t in TASKS]


def select_tasks(n: int, seed: int) -> list[tuple[str, object]]:
    """Return ``n`` tasks (cycling the suite) with a seed-based start offset."""
    if n < 1:
        raise ValueError("n must be >= 1")
    start = seed % len(TASKS)
    out: list[tuple[str, object]] = []
    for i in range(n):
        out.append(TASKS[(start + i) % len(TASKS)])
    return out

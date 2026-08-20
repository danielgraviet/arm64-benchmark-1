"""Task registry for TB-style eval trials.

The ladder runs **log-surgery** only so duration_ms is one workload shape.
Other modules stay in-tree for optional local checks; they are not selected.
"""

from __future__ import annotations

from evals.tasks import log_surgery

PRIMARY_TASK_ID = "log-surgery"

TASKS: list[tuple[str, object]] = [
    (PRIMARY_TASK_ID, log_surgery),
]

TASK_IDS = [t[0] for t in TASKS]


def select_tasks(n: int, seed: int) -> list[tuple[str, object]]:
    """Always return log-surgery. ``n`` and ``seed`` do not pick a different task.

    ``seed`` still flows into setup/oracle so the log stream is deterministic.
    ``n`` is kept for CLI parity; a trial always runs one task.
    """
    if n < 1:
        raise ValueError("n must be >= 1")
    _ = n, seed
    return [TASKS[0]]

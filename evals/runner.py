"""Run a Terminal-Bench–style eval trial: setup → oracle → verify.

One invocation = one log-surgery task (one sandbox). Concurrent jobs share
the same seed so duration_ms is comparable across the ladder.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

from evals.tasks import select_tasks


def run_trial(n: int, seed: int) -> dict[str, Any]:
    """Execute one TB-inspired task in an isolated workspace.

    ``n`` is accepted for CLI/harness parity and ignored (always one task).
    """
    _ = n
    selected = select_tasks(1, seed)
    task_results: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="vera-evals-") as tmp:
        root = Path(tmp)
        for idx, (task_id, mod) in enumerate(selected):
            workspace = root / f"task-{idx}-{task_id}"
            workspace.mkdir(parents=True)
            mod.setup(workspace, seed)
            oracle_meta = mod.oracle(workspace, seed)
            verify_meta = mod.verify(workspace)
            task_results.append(
                {
                    "task_id": task_id,
                    "index": idx,
                    "oracle": oracle_meta,
                    "verify": verify_meta,
                    "passed": bool(verify_meta.get("passed")),
                }
            )

    all_passed = all(r["passed"] for r in task_results)
    return {
        "n": 1,
        "seed": seed,
        "task_ids": [r["task_id"] for r in task_results],
        "tasks": task_results,
        "passed": all_passed,
        "passed_count": sum(1 for r in task_results if r["passed"]),
    }

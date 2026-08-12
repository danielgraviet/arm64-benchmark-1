"""Run a Terminal-Bench–style eval trial: setup → oracle → verify."""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

from evals.tasks import select_tasks


def run_trial(n: int, seed: int) -> dict[str, Any]:
    """Execute ``n`` TB-inspired tasks in an isolated workspace.

    Returns a structured result used for checksum + pass/fail.
    """
    selected = select_tasks(n, seed)
    task_results: list[dict[str, Any]] = []

    with tempfile.TemporaryDirectory(prefix="vera-evals-") as tmp:
        root = Path(tmp)
        for idx, (task_id, mod) in enumerate(selected):
            workspace = root / f"task-{idx}-{task_id}"
            workspace.mkdir(parents=True)
            mod.setup(workspace, seed + idx)
            oracle_meta = mod.oracle(workspace, seed + idx)
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
        "n": n,
        "seed": seed,
        "task_ids": [r["task_id"] for r in task_results],
        "tasks": task_results,
        "passed": all_passed,
        "passed_count": sum(1 for r in task_results if r["passed"]),
    }

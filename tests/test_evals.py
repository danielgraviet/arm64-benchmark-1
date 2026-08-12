"""Unit tests for Terminal-Bench–style evals suite."""

from __future__ import annotations

from evals.agent import compute_checksum
from evals.runner import run_trial
from evals.tasks import TASK_IDS, select_tasks


def test_select_tasks_cycles() -> None:
    picked = select_tasks(n=6, seed=0)
    assert len(picked) == 6
    assert picked[0][0] == TASK_IDS[0]
    assert picked[4][0] == TASK_IDS[0]


def test_trial_passes_and_deterministic() -> None:
    a = run_trial(n=4, seed=42)
    b = run_trial(n=4, seed=42)
    assert a["passed"] is True
    assert a["passed_count"] == 4
    assert a["task_ids"] == b["task_ids"]
    assert a["passed"] == b["passed"]


def test_single_task_trial_is_multi_hundred_ms() -> None:
    """Chart B uses --n 1; each hero task should not be create-tax-only."""
    import time

    start = time.perf_counter()
    result = run_trial(n=1, seed=0)  # fix-failing-tests
    elapsed_ms = (time.perf_counter() - start) * 1000
    assert result["passed"] is True
    assert elapsed_ms >= 500


def test_seed_changes_task_rotation() -> None:
    a = run_trial(n=2, seed=0)
    b = run_trial(n=2, seed=1)
    assert a["task_ids"] != b["task_ids"] or a["seed"] != b["seed"]


def test_checksum_stable_for_same_trial_shape() -> None:
    a = run_trial(n=2, seed=7)
    b = run_trial(n=2, seed=7)
    stable_a = {
        "n": a["n"],
        "seed": a["seed"],
        "task_ids": a["task_ids"],
        "passed": a["passed"],
        "passed_count": a["passed_count"],
        "per_task": [
            {
                "task_id": t["task_id"],
                "passed": t["passed"],
                "verify_passed": t["verify"].get("passed"),
            }
            for t in a["tasks"]
        ],
    }
    stable_b = {
        "n": b["n"],
        "seed": b["seed"],
        "task_ids": b["task_ids"],
        "passed": b["passed"],
        "passed_count": b["passed_count"],
        "per_task": [
            {
                "task_id": t["task_id"],
                "passed": t["passed"],
                "verify_passed": t["verify"].get("passed"),
            }
            for t in b["tasks"]
        ],
    }
    assert compute_checksum(stable_a) == compute_checksum(stable_b)

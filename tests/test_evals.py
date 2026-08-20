"""Unit tests for Terminal-Bench–style evals suite (log-surgery ladder)."""

from __future__ import annotations

import tempfile
from pathlib import Path

from evals.agent import compute_checksum
from evals.runner import run_trial
from evals.tasks import PRIMARY_TASK_ID, select_tasks
from evals.tasks import fix_failing_tests
from evals.tasks.fix_failing_tests import VISIBLE_TESTS


def test_select_tasks_always_log_surgery() -> None:
    picked = select_tasks(n=6, seed=0)
    assert len(picked) == 1
    assert picked[0][0] == PRIMARY_TASK_ID
    assert select_tasks(n=1, seed=99)[0][0] == PRIMARY_TASK_ID


def test_one_task_per_trial() -> None:
    result = run_trial(n=4, seed=42)  # n is ignored
    assert result["n"] == 1
    assert result["passed"] is True
    assert result["passed_count"] == 1
    assert result["task_ids"] == [PRIMARY_TASK_ID]


def test_seed_does_not_change_task() -> None:
    ids = [run_trial(n=1, seed=s)["task_ids"][0] for s in range(4)]
    assert ids == [PRIMARY_TASK_ID] * 4


def test_trial_deterministic() -> None:
    a = run_trial(n=1, seed=42)
    b = run_trial(n=1, seed=42)
    assert a["task_ids"] == b["task_ids"] == [PRIMARY_TASK_ID]
    assert a["passed"] == b["passed"]


def test_log_surgery_trial_is_multi_hundred_ms() -> None:
    """log-surgery should not be create-tax-only."""
    import time

    start = time.perf_counter()
    result = run_trial(n=1, seed=42)
    elapsed_ms = (time.perf_counter() - start) * 1000
    assert result["passed"] is True
    assert result["task_ids"] == [PRIMARY_TASK_ID]
    assert elapsed_ms >= 500


def test_hidden_tests_exist_on_unused_fix_failing_module() -> None:
    assert "hidden/test_extra.py" not in VISIBLE_TESTS
    assert VISIBLE_TESTS == ("test_mathy.py", "test_stats.py", "test_texty.py")
    with tempfile.TemporaryDirectory(prefix="vera-evals-fft-") as tmp:
        workspace = Path(tmp)
        fix_failing_tests.setup(workspace, seed=0)
        oracle = fix_failing_tests.oracle(workspace, seed=0)
        verify = fix_failing_tests.verify(workspace)
    assert oracle
    assert verify.get("passed") is True


def test_checksum_stable_for_same_trial_shape() -> None:
    a = run_trial(n=1, seed=7)
    b = run_trial(n=1, seed=7)
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
    other = run_trial(n=1, seed=8)
    assert other["task_ids"] == a["task_ids"]
    other_stable = {
        "n": other["n"],
        "seed": other["seed"],
        "task_ids": other["task_ids"],
        "passed": other["passed"],
        "passed_count": other["passed_count"],
        "per_task": [
            {
                "task_id": t["task_id"],
                "passed": t["passed"],
                "verify_passed": t["verify"].get("passed"),
            }
            for t in other["tasks"]
        ],
    }
    assert compute_checksum(stable_a) != compute_checksum(other_stable)

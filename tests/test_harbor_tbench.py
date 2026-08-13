"""Unit tests for Harbor Terminal-Bench Phase 2 runner (no live Harbor required)."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from harness.runners.harbor import (
    HarborRunner,
    _extract_job_id,
    _extract_pass_rate,
    _read_job_stats,
    run_harbor_suite,
)


def test_build_argv_with_task_limit(tmp_path: Path) -> None:
    runner = HarborRunner(harbor_bin="harbor", jobs_dir=tmp_path)
    argv = runner.build_argv(concurrency=5, task_limit=5, job_name="job-x")
    assert argv[:8] == [
        "harbor",
        "run",
        "-d",
        "terminal-bench/terminal-bench-2",
        "-a",
        "oracle",
        "--env",
        "daytona",
    ]
    assert "-n" in argv and "5" in argv
    assert "-l" in argv and argv[argv.index("-l") + 1] == "5"
    assert "--job-name" in argv and "job-x" in argv
    assert "-o" in argv and str(tmp_path) in argv


def test_build_argv_no_limit_when_n_zero(tmp_path: Path) -> None:
    runner = HarborRunner(harbor_bin="harbor", jobs_dir=tmp_path)
    argv = runner.build_argv(concurrency=32, task_limit=0, job_name="job-y")
    assert "-l" not in argv
    assert argv[argv.index("-n") + 1] == "32"


def test_extract_pass_rate_and_job_id() -> None:
    text = (
        "Running trials…\n"
        "Success: 5/5 (100.0%)\n"
        "Results in jobs/abc-123-def\n"
    )
    assert _extract_pass_rate(text) == pytest.approx(1.0)
    assert _extract_job_id(text) == "abc-123-def"
    assert _extract_job_id("jobs/2026-08-12__15-48-49`") == "2026-08-12__15-48-49"


def test_read_job_stats(tmp_path: Path) -> None:
    (tmp_path / "result.json").write_text(
        json.dumps(
            {
                "stats": {
                    "n_completed_trials": 5,
                    "n_errored_trials": 0,
                    "evals": {
                        "oracle__terminal-bench/terminal-bench-2": {
                            "metrics": [{"mean": 0.8}]
                        }
                    },
                }
            }
        ),
        encoding="utf-8",
    )
    stats = _read_job_stats(tmp_path)
    assert stats["mean_reward"] == pytest.approx(0.8)
    assert stats["n_completed_trials"] == 5


def test_run_job_sets_daytona_target_env(tmp_path: Path) -> None:
    runner = HarborRunner(
        harbor_bin="harbor", target="vera-region-1", jobs_dir=tmp_path
    )
    job_dir = tmp_path / "placeholder"
    # run_job creates a timestamped name; mock subprocess and plant result.json
    # after we know the name via side_effect.
    fake = MagicMock()
    fake.returncode = 0
    fake.stdout = "ok\n"
    fake.stderr = ""

    def _run(argv, **kwargs):  # noqa: ANN001
        name = argv[argv.index("--job-name") + 1]
        d = tmp_path / name
        d.mkdir(parents=True)
        (d / "result.json").write_text(
            json.dumps(
                {
                    "stats": {
                        "n_completed_trials": 5,
                        "n_errored_trials": 0,
                        "evals": {"oracle__x": {"metrics": [{"mean": 1.0}]}},
                    }
                }
            ),
            encoding="utf-8",
        )
        return fake

    with patch("harness.runners.harbor.subprocess.run", side_effect=_run) as run:
        record = runner.run_job(concurrency=5, task_limit=5, seed=42)
    assert record["exit_code"] == 0
    assert record["pass_rate"] == pytest.approx(1.0)
    assert record["n_completed_trials"] == 5
    env = run.call_args.kwargs["env"]
    assert env["DAYTONA_TARGET"] == "vera-region-1"
    _ = job_dir


def test_run_harbor_suite_one_job_per_level(tmp_path: Path) -> None:
    out = tmp_path / "out.jsonl"
    runner = MagicMock(spec=HarborRunner)
    runner.run_job.side_effect = [
        {
            "latency_ms": 1000.0,
            "duration_ms": 1000.0,
            "exit_code": 0,
            "checksum": "c1",
            "pass_rate": 1.0,
        },
        {
            "latency_ms": 2000.0,
            "duration_ms": 2000.0,
            "exit_code": 0,
            "checksum": "c2",
            "pass_rate": 1.0,
        },
    ]
    run_harbor_suite(
        levels=[5, 32],
        task_limit=5,
        seed=1,
        output=out,
        runner=runner,
        meta={"benchmark": "tbench", "runner": "harbor"},
    )
    assert runner.run_job.call_count == 2
    assert runner.run_job.call_args_list[0].kwargs["concurrency"] == 5
    assert runner.run_job.call_args_list[1].kwargs["concurrency"] == 32
    lines = out.read_text(encoding="utf-8").strip().splitlines()
    types = [json.loads(ln)["type"] for ln in lines]
    assert types == ["meta", "run", "summary", "run", "summary"]

from pathlib import Path

from workload import run_tests


def test_run_tests_passes_selected_suite(vendored_repo: Path) -> None:
    result = run_tests.run(vendored_repo)

    assert result["exit_code"] == 0
    assert result["total"] == 111
    assert result["passed"] == 111
    assert result["failed_tests"] == []

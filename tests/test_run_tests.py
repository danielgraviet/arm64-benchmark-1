from pathlib import Path

from workload import run_tests


def test_run_tests_passes_selected_suite(vendored_repo: Path) -> None:
    # n=20 → 1 + 20//5 = 5 files (original suite size)
    result = run_tests.run(vendored_repo, n=20)

    assert result["exit_code"] == 0
    assert len(result["files_selected"]) == 5
    assert result["failed_tests"] == []
    assert result["passed"] == result["total"]
    assert result["total"] > 0


def test_run_tests_scales_with_n(vendored_repo: Path) -> None:
    small = run_tests.run(vendored_repo, n=1)
    large = run_tests.run(vendored_repo, n=40)
    assert len(small["files_selected"]) == 1
    assert len(large["files_selected"]) >= len(small["files_selected"])

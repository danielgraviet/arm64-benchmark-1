import contextlib
import io
from pathlib import Path
from typing import Any

import pytest

TEST_FILES = [
    "tests/test_fts.py",
    "tests/test_analyze_tables.py",
    "tests/test_m2m.py",
    "tests/test_extract.py",
    "tests/test_upsert.py",
]


class _ResultCollector:
    def __init__(self) -> None:
        self.outcomes: dict[str, str] = {}

    def pytest_runtest_logreport(self, report: pytest.TestReport) -> None:
        if report.when == "call" or (
            report.when == "setup" and report.outcome != "passed"
        ):
            self.outcomes[report.nodeid] = report.outcome


def run(repo_root: Path) -> dict[str, Any]:
    collector = _ResultCollector()
    args = [str(repo_root / f) for f in TEST_FILES] + [
        "-q",
        "-p",
        "no:cacheprovider",
    ]
    with contextlib.redirect_stdout(io.StringIO()):
        exit_code = pytest.main(args, plugins=[collector])

    prefix = str(repo_root) + "/"
    outcomes = {
        nodeid.removeprefix(prefix): outcome
        for nodeid, outcome in collector.outcomes.items()
    }
    passed = sorted(nodeid for nodeid, outcome in outcomes.items() if outcome == "passed")
    failed = sorted(nodeid for nodeid, outcome in outcomes.items() if outcome != "passed")

    return {
        "exit_code": exit_code,
        "total": len(outcomes),
        "passed": len(passed),
        "failed_tests": failed,
    }

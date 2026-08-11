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
    "tests/test_create.py",
    "tests/test_insert_files.py",
    "tests/test_query.py",
    "tests/test_transform.py",
    "tests/test_utils.py",
]


class _ResultCollector:
    def __init__(self) -> None:
        self.outcomes: dict[str, str] = {}

    def pytest_runtest_logreport(self, report: pytest.TestReport) -> None:
        if report.when == "call" or (
            report.when == "setup" and report.outcome != "passed"
        ):
            self.outcomes[report.nodeid] = report.outcome


def run(repo_root: Path, n: int = 5) -> dict[str, Any]:
    """Run a deterministic subset of pytest files; breadth scales with ``n``.

    Chart B light profile (``n=20``) still runs several files; larger ``n``
    widens the suite up to ``len(TEST_FILES)``.
    """
    if n < 1:
        raise ValueError("n must be >= 1")
    # At least 1 file; grow with n but cap at available suite.
    count = max(1, min(len(TEST_FILES), 1 + (n // 5)))
    selected = TEST_FILES[:count]

    collector = _ResultCollector()
    args = [str(repo_root / f) for f in selected] + [
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
        "files_selected": selected,
        "total": len(outcomes),
        "passed": len(passed),
        "failed_tests": failed,
    }

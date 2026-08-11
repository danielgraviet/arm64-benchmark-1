"""Single-agent workload entrypoint (runs inside Docker / sandbox workers)."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VENDORED_REPO = REPO_ROOT / "workload" / "repos" / "sqlite-utils"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vera agent benchmark workload")
    parser.add_argument(
        "--n",
        type=int,
        default=10,
        help="Work volume (search/AST/edit/test breadth, SQL scale)",
    )
    parser.add_argument(
        "--task",
        type=str,
        default="repo-agent-v2",
        help="Workload scenario name",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Fixed random seed for the SQL data generation step",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="json",
        choices=["json"],
        help="Output format",
    )
    return parser.parse_args()


def compute_checksum(*parts: object) -> str:
    hasher = hashlib.sha256()
    for part in parts:
        hasher.update(json.dumps(part, sort_keys=True).encode("utf-8"))
    return hasher.hexdigest()


def _prepare_workspace() -> tuple[Path, tempfile.TemporaryDirectory[str]]:
    """Copy vendored repo to an isolated tmp tree (safe under concurrency / reuse)."""
    tmp = tempfile.TemporaryDirectory(prefix="vera-agent-")
    dest = Path(tmp.name) / "sqlite-utils"
    shutil.copytree(
        VENDORED_REPO,
        dest,
        ignore=shutil.ignore_patterns(
            ".git",
            "__pycache__",
            "*.pyc",
            ".pytest_cache",
            ".venv",
            "venv",
            "node_modules",
        ),
    )
    return dest, tmp


def main() -> None:
    # Import after path setup so vendored sqlite_utils resolves for sql step.
    sys.path.insert(0, str(VENDORED_REPO))
    from workload import ast_parse, edit, run_tests, search, sql

    args = parse_args()
    workspace, tmp = _prepare_workspace()
    start = time.perf_counter()
    try:
        # Multi-step tool loop (offline, no LLM): search → AST → edit → test → SQL.
        # Each step scales with --n; Chart B keeps --n 20 as the light density profile.
        search_result = search.run(workspace, n=args.n)
        ast_result = ast_parse.run(workspace, n=args.n)
        edit_result = edit.run(workspace, n=args.n)
        test_result = run_tests.run(workspace, n=args.n)
        sql_result = sql.run(n=args.n, seed=args.seed)

        duration_ms = int((time.perf_counter() - start) * 1000)
        checksum = compute_checksum(
            search_result, ast_result, edit_result, test_result, sql_result
        )
        print(
            json.dumps(
                {
                    "task": args.task,
                    "iterations": args.n,
                    "duration_ms": duration_ms,
                    "checksum": checksum,
                }
            )
        )
    finally:
        tmp.cleanup()


if __name__ == "__main__":
    main()

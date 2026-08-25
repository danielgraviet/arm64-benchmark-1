"""Single-agent workload entrypoint (runs inside Docker / sandbox workers).

Default task ``repo-agent-v3`` is a Daytona-shaped coding loop (search → AST →
edit → pytest) with no SQL. Legacy ``repo-agent-v2`` remains for old images.
"""

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
        help="Work volume (search/AST breadth and pytest case scale)",
    )
    parser.add_argument(
        "--task",
        type=str,
        default="repo-agent-v3",
        help="Workload scenario (repo-agent-v3 default; repo-agent-v2 legacy)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Fixed random seed for workspace generation",
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


def _prepare_sqlite_workspace() -> tuple[Path, tempfile.TemporaryDirectory[str]]:
    """Copy vendored repo to an isolated tmp tree (legacy v2)."""
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


def _run_v2(args: argparse.Namespace) -> None:
    sys.path.insert(0, str(VENDORED_REPO))
    from workload import ast_parse, edit, run_tests, search, sql

    workspace, tmp = _prepare_sqlite_workspace()
    start = time.perf_counter()
    try:
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


def _run_v3(args: argparse.Namespace) -> None:
    from workload.coding_loop import run_coding_loop

    tmp = tempfile.TemporaryDirectory(prefix="vera-agent-v3-")
    workspace = Path(tmp.name) / "project"
    workspace.mkdir()
    start = time.perf_counter()
    try:
        steps = run_coding_loop(workspace, n=args.n, seed=args.seed)
        duration_ms = int((time.perf_counter() - start) * 1000)
        checksum = compute_checksum(
            steps["seed"],
            steps["search"],
            steps["ast"],
            steps["edit"],
            steps["verify"],
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


def main() -> None:
    args = parse_args()
    if args.task == "repo-agent-v2":
        _run_v2(args)
        return
    if args.task in ("repo-agent-v3", "repo-agent-v2-coding"):
        _run_v3(args)
        return
    # Unknown task names still run v3 (harness default).
    _run_v3(args)


if __name__ == "__main__":
    main()

"""Single-agent workload entrypoint (runs inside Docker / sandbox workers)."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
VENDORED_REPO = REPO_ROOT / "workload" / "repos" / "sqlite-utils"

sys.path.insert(0, str(VENDORED_REPO))

from workload import ast_parse, edit, run_tests, search, sql


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vera agent benchmark workload")
    parser.add_argument(
        "--n",
        type=int,
        default=10,
        help="Work volume for this run (files touched, SQL rows inserted)",
    )
    parser.add_argument(
        "--task",
        type=str,
        default="repo-agent-v1",
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


def main() -> None:
    args = parse_args()
    start = time.perf_counter()

    search_result = search.run(VENDORED_REPO, n=args.n)
    ast_result = ast_parse.run(VENDORED_REPO, n=args.n)
    edit_result = edit.run(VENDORED_REPO)
    test_result = run_tests.run(VENDORED_REPO)
    sql_result = sql.run(n=args.n, seed=args.seed)

    duration_ms = int((time.perf_counter() - start) * 1000)

    checksum = compute_checksum(
        search_result, ast_result, edit_result, test_result, sql_result
    )

    output = {
        "task": args.task,
        "iterations": args.n,
        "duration_ms": duration_ms,
        "checksum": checksum,
    }
    print(json.dumps(output))


if __name__ == "__main__":
    main()

"""Evals benchmark entrypoint (Docker / sandbox workers).

Terminal-Bench–style trial: isolated workspace → oracle terminal work → verify.
No LLM. One sandbox = log-surgery (same task at every concurrency).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time

from evals import runner


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Vera Terminal-Bench–style evals workload"
    )
    parser.add_argument(
        "--n",
        type=int,
        default=1,
        help="Unused (one task per sandbox). Kept so the shared harness CLI matches other benches.",
    )
    parser.add_argument(
        "--task",
        type=str,
        default="evals-tb-style-v3",
        help="Workload scenario name",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Deterministic seed for the log-surgery workload (all sandboxes share it)",
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
    result = runner.run_trial(n=args.n, seed=args.seed)
    duration_ms = int((time.perf_counter() - start) * 1000)
    # Checksum omits free-form stdout tails that may vary by pytest version noise;
    # keep stable pass bits + task ids.
    stable = {
        "n": result["n"],
        "seed": result["seed"],
        "task_ids": result["task_ids"],
        "passed": result["passed"],
        "passed_count": result["passed_count"],
        "per_task": [
            {
                "task_id": t["task_id"],
                "passed": t["passed"],
                "verify_passed": t["verify"].get("passed"),
            }
            for t in result["tasks"]
        ],
    }
    checksum = compute_checksum(stable)
    payload = {
        "task": args.task,
        "iterations": 1,
        "duration_ms": duration_ms,
        "checksum": checksum,
        "eval_task_id": result["task_ids"][0] if result["task_ids"] else None,
        "passed": result["passed"],
        "passed_count": result["passed_count"],
    }
    print(json.dumps(payload))
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

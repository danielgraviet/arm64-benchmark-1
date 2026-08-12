"""Evals benchmark entrypoint (Docker / sandbox workers).

Terminal-Bench–style trial: isolated workspace → oracle terminal work → verify.
No LLM. Harness concurrency = many trials; ``--n`` = tasks per trial
(Chart B density uses ``--n 1`` ≈ one TB task per sandbox).
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
        help="Tasks per trial (Chart B density: --n 1 ≈ one TB task per sandbox)",
    )
    parser.add_argument(
        "--task",
        type=str,
        default="evals-tb-style-v2",
        help="Workload scenario name",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Fixed seed for task rotation / setup variants",
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
        "iterations": args.n,
        "duration_ms": duration_ms,
        "checksum": checksum,
        "passed": result["passed"],
        "passed_count": result["passed_count"],
    }
    print(json.dumps(payload))
    if not result["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

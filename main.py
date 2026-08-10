"""Central concurrency harness CLI.

Examples:
  uv run main.py --runner daytona --levels 1 2 8 --n 20
  uv run main.py --runner docker --levels 1 8 --n 20
  uv run main.py --runner ec2 --levels 1 8 --n 20
  uv run main.py --runner rlp --levels 1 --n 20
"""

from __future__ import annotations

import argparse
from pathlib import Path

from harness.common import run_suite
from harness.paths import default_output_path
from harness.runners import docker, ec2
from harness.runners.daytona import DaytonaRunner
from harness.runners.rlp import RlpRunner

RUNNERS = ("docker", "daytona", "rlp", "ec2")


def build_run_one(args: argparse.Namespace):
    if args.runner == "docker":
        return docker.run_one
    if args.runner == "ec2":
        return ec2.run_one
    if args.runner == "daytona":
        return DaytonaRunner(
            snapshot=args.snapshot,
            exec_timeout_s=args.exec_timeout,
        ).run_one
    if args.runner == "rlp":
        return RlpRunner(
            snapshot=args.snapshot,
            exec_timeout_s=args.exec_timeout,
        ).run_one
    raise ValueError(f"Unknown runner: {args.runner}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Vera concurrency harness")
    parser.add_argument(
        "--runner",
        required=True,
        choices=RUNNERS,
        help="Worker backend / result folder under data/",
    )
    parser.add_argument(
        "--levels", type=int, nargs="+", default=[1, 8, 22, 44, 88, 176]
    )
    parser.add_argument("--n", type=int, default=20)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help="Override JSONL path (default: data/<runner>/concurrency_<ts>_n<n>.jsonl)",
    )
    parser.add_argument(
        "--snapshot",
        type=str,
        default="vera-agent-benchmark",
        help="Snapshot name for daytona/rlp runners",
    )
    parser.add_argument(
        "--exec-timeout",
        type=int,
        default=600,
        help="Seconds allowed for process.exec inside each sandbox (daytona/rlp)",
    )
    args = parser.parse_args()

    output = (
        Path(args.output)
        if args.output
        else default_output_path(args.runner, args.n)
    )
    print(f"runner={args.runner} output={output}")

    run_suite(
        levels=args.levels,
        n=args.n,
        seed=args.seed,
        output=output,
        run_one=build_run_one(args),
    )


if __name__ == "__main__":
    main()

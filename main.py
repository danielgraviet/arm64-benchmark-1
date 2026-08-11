"""Central concurrency harness CLI.

Examples:
  uv run main.py --benchmark agent --runner daytona --levels 1 8 --n 20
  uv run main.py --benchmark analytics --runner docker --levels 1 8 --n 5
  uv run main.py --benchmark agent --runner rlp --target arm64-test-1 --levels 1 8
"""

from __future__ import annotations

import argparse
from pathlib import Path

from harness.benchmarks import BENCHMARK_IDS, get_benchmark
from harness.common import run_suite
from harness.paths import default_output_path
from harness.runners import RUNNERS, build_run_one


def main() -> None:
    parser = argparse.ArgumentParser(description="Vera concurrency harness")
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=BENCHMARK_IDS,
        help="Workload package (agent=B1, analytics=B2)",
    )
    parser.add_argument(
        "--runner",
        required=True,
        choices=RUNNERS,
        help="Worker backend / result folder under data/<benchmark>/",
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
        help=(
            "Override JSONL path (default: data/<benchmark>/<series>/"
            "concurrency_<ts>_n<n>.jsonl; RLP uses rlp-x86 or rlp-arm64)"
        ),
    )
    parser.add_argument(
        "--snapshot",
        type=str,
        default=None,
        help="Override snapshot/template name (default: per-benchmark artifact)",
    )
    parser.add_argument(
        "--exec-timeout",
        type=int,
        default=600,
        help="Seconds allowed for process.exec inside each sandbox",
    )
    parser.add_argument(
        "--target",
        type=str,
        default=None,
        help=(
            "Region/target for daytona/rlp (e.g. arm64-test-1). "
            "RLP maps known targets to the matching toolbox URL."
        ),
    )
    parser.add_argument(
        "--toolbox-url",
        type=str,
        default=None,
        help="Override RLP toolbox proxy URL (defaults from --target map or env)",
    )
    args = parser.parse_args()

    if args.toolbox_url and args.runner != "rlp":
        parser.error("--toolbox-url is only valid with --runner rlp")
    if args.target and args.runner not in ("daytona", "rlp"):
        parser.error("--target is only valid with --runner daytona or rlp")

    spec = get_benchmark(args.benchmark)
    artifact = (
        args.snapshot
        if args.snapshot
        else (
            spec.artifact_for_target(args.target)
            if args.runner == "rlp"
            else spec.artifact_name
        )
    )
    output = (
        Path(args.output)
        if args.output
        else default_output_path(
            args.runner,
            args.n,
            benchmark=args.benchmark,
            target=args.target,
        )
    )
    print(
        f"benchmark={args.benchmark} runner={args.runner} "
        f"target={args.target!r} artifact={artifact!r} "
        f"output={output}"
    )

    run_suite(
        levels=args.levels,
        n=args.n,
        seed=args.seed,
        output=output,
        run_one=build_run_one(args),
        meta={
            "benchmark": args.benchmark,
            "runner": args.runner,
            "target": args.target,
            "artifact": artifact,
            "seed": args.seed,
            "n": args.n,
        },
    )


if __name__ == "__main__":
    main()

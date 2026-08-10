"""Central concurrency harness CLI.

Examples:
  uv run main.py --runner daytona --levels 1 2 8 --n 20
  uv run main.py --runner docker --levels 1 8 --n 20
  uv run main.py --runner e2b --levels 1 8 --n 20
  uv run main.py --runner ec2 --levels 1 8 --n 20
  uv run main.py --runner rlp --levels 1 --n 20
  uv run main.py --runner rlp --target arm64-test-1 --levels 1 8 --n 20
"""

from __future__ import annotations

import argparse
from pathlib import Path

from harness.common import run_suite
from harness.paths import default_output_path
from harness.runners import RUNNERS, build_run_one


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
        help=(
            "Override JSONL path (default: data/<runner>/[target/]"
            "concurrency_<ts>_n<n>.jsonl)"
        ),
    )
    parser.add_argument(
        "--snapshot",
        type=str,
        default="vera-agent-benchmark",
        help="Snapshot/template name for daytona/rlp/e2b runners",
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

    output = (
        Path(args.output)
        if args.output
        else default_output_path(args.runner, args.n, target=args.target)
    )
    print(f"runner={args.runner} target={args.target!r} output={output}")

    run_suite(
        levels=args.levels,
        n=args.n,
        seed=args.seed,
        output=output,
        run_one=build_run_one(args),
    )


if __name__ == "__main__":
    main()

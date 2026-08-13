"""Central concurrency harness CLI.

Examples:
  uv run main.py --benchmark agent --runner daytona --levels 1 8 --n 20
  uv run main.py --benchmark analytics --runner docker --levels 1 8 --n 5
  uv run main.py --benchmark rl --runner docker --levels 1 8 22 --n 64
  uv run main.py --benchmark rl --runner daytona --levels 1 --n 5000 -E 8
  uv run main.py --benchmark agent --runner rlp --target arm64-test-1 --levels 1 8
  uv run main.py --benchmark tbench --runner harbor --levels 5 --n 5
"""

from __future__ import annotations

import argparse
from pathlib import Path

from harness.benchmarks import BENCHMARK_IDS, TBENCH, get_benchmark
from harness.common import run_suite
from harness.paths import default_output_path
from harness.runners import RUNNERS, build_run_worker
from harness.runners.harbor import HarborRunner, run_harbor_suite


def main() -> None:
    parser = argparse.ArgumentParser(description="Vera concurrency harness")
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=BENCHMARK_IDS,
        help="Workload package (agent|analytics|rl|evals|tbench)",
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
    parser.add_argument(
        "--n",
        type=int,
        default=20,
        help=(
            "Work volume for in-repo benches; for tbench/harbor = Harbor -l "
            "task limit (0 = no limit / full pack)"
        ),
    )
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--episodes-per-sandbox",
        "-E",
        type=int,
        default=1,
        help=(
            "Episodes to exec per sandbox before delete (daytona/rlp). "
            "Default 1 = Chart B density. Use E>=8 for Chart A warm chip runs."
        ),
    )
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
            "Region/target for daytona/rlp/harbor (e.g. arm64-test-1). "
            "Harbor forwards as DAYTONA_TARGET until the region flag is frozen."
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
    if args.target and args.runner not in ("daytona", "rlp", "harbor"):
        parser.error("--target is only valid with --runner daytona, rlp, or harbor")
    if args.episodes_per_sandbox < 1:
        parser.error("--episodes-per-sandbox must be >= 1")
    if args.episodes_per_sandbox > 1 and args.runner not in ("daytona", "rlp"):
        parser.error(
            "--episodes-per-sandbox > 1 is only supported with --runner daytona or rlp"
        )
    if args.n < 0:
        parser.error("--n must be >= 0 (0 = no Harbor task limit for tbench)")

    # tbench is Harbor-only; other benches cannot use --runner harbor.
    if args.benchmark == TBENCH.id and args.runner != "harbor":
        parser.error(
            "--benchmark tbench requires --runner harbor "
            "(real Terminal-Bench is not a docker/daytona workload image). "
            "For TB-style in-repo density use: --benchmark evals"
        )
    if args.runner == "harbor" and args.benchmark != TBENCH.id:
        parser.error(
            "--runner harbor requires --benchmark tbench "
            "(Phase 1 TB-style pack is --benchmark evals)"
        )

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
        f"episodes_per_sandbox={args.episodes_per_sandbox} "
        f"output={output}"
    )

    meta = {
        "benchmark": args.benchmark,
        "runner": args.runner,
        "target": args.target,
        "artifact": artifact,
        "seed": args.seed,
        "n": args.n,
        "episodes_per_sandbox": args.episodes_per_sandbox,
    }

    if args.runner == "harbor":
        run_harbor_suite(
            levels=args.levels,
            task_limit=args.n,
            seed=args.seed,
            output=output,
            runner=HarborRunner(target=args.target),
            meta=meta,
        )
        return

    run_suite(
        levels=args.levels,
        n=args.n,
        seed=args.seed,
        output=output,
        run_worker=build_run_worker(args),
        meta=meta,
    )


if __name__ == "__main__":
    main()

"""Agent concurrency harness (on-node RLP).

  uv run main.py --benchmark agent --runner rlp --target local --levels 1 --n 1
  bash scripts/run_ladder.sh
"""

from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path

from harness.benchmarks import BENCHMARK_IDS, get_benchmark
from harness.common import run_hold_suite, run_suite
from harness.paths import default_output_path
from harness.rlimit_nofile import require_nofile
from harness.rlp_client_tuning import settings as rlp_client_tuning_settings
from harness.runners import RUNNERS, build_runner, probe_runner_env, runner_as_worker


def main() -> None:
    parser = argparse.ArgumentParser(description="Agent concurrency harness")
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=BENCHMARK_IDS,
    )
    parser.add_argument(
        "--runner",
        required=True,
        choices=RUNNERS,
        help="rlp = on-node cell. docker = local image smoke.",
    )
    parser.add_argument(
        "--levels", type=int, nargs="+", default=[1, 8, 22, 44, 88, 176]
    )
    parser.add_argument("--n", type=int, default=50)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--episodes-per-sandbox",
        "-E",
        type=int,
        default=1,
        help="Execs per sandbox before delete. The packed ladder uses -E 8.",
    )
    parser.add_argument("--output", type=str, default=None)
    parser.add_argument(
        "--snapshot",
        type=str,
        default=None,
        help="Override image. Default is dtgraviet/vera-agent-benchmark:v3",
    )
    parser.add_argument("--exec-timeout", type=int, default=600)
    parser.add_argument(
        "--target",
        type=str,
        default="local",
        help="Must be local (localhost RLP). Do not change.",
    )
    parser.add_argument("--toolbox-url", type=str, default=None)
    parser.add_argument("--rlp-cpu", type=float, default=1.0)
    parser.add_argument("--rlp-cpu-max", type=float, default=None)
    parser.add_argument("--rlp-memory", type=float, default=None)
    parser.add_argument("--rlp-memory-max", type=float, default=None)
    parser.add_argument("--rlp-disk", type=float, default=None)
    parser.add_argument("--host-cpus", type=int, default=None)
    parser.add_argument("--numa-node", type=int, default=None)
    parser.add_argument("--cpuset-mems", type=str, default=None)
    parser.add_argument(
        "--hold-then-exec",
        action="store_true",
        help="RLP only. Create the fleet, then exec, then delete.",
    )
    args = parser.parse_args()

    if args.toolbox_url and args.runner != "rlp":
        parser.error("--toolbox-url is only valid with --runner rlp")
    if args.target and args.runner != "rlp":
        parser.error("--target is only valid with --runner rlp")
    if args.rlp_cpu != 1.0 and args.runner != "rlp":
        parser.error("--rlp-cpu is only valid with --runner rlp")
    if args.rlp_cpu <= 0:
        parser.error("--rlp-cpu must be > 0")
    burst_flags = (
        args.rlp_cpu_max is not None
        or args.rlp_memory is not None
        or args.rlp_memory_max is not None
        or args.rlp_disk is not None
    )
    if burst_flags and args.runner != "rlp":
        parser.error("RLP resource flags are only valid with --runner rlp")
    if args.rlp_cpu_max is not None and args.rlp_cpu_max < args.rlp_cpu:
        parser.error("--rlp-cpu-max must be >= --rlp-cpu")
    if (
        args.rlp_memory_max is not None
        and args.rlp_memory is not None
        and args.rlp_memory_max < args.rlp_memory
    ):
        parser.error("--rlp-memory-max must be >= --rlp-memory")
    if args.host_cpus is not None and args.runner != "docker":
        parser.error("--host-cpus is only valid with --runner docker")
    if args.host_cpus is not None and args.host_cpus < 1:
        parser.error("--host-cpus must be >= 1")
    if args.numa_node is not None and args.runner != "docker":
        parser.error("--numa-node is only valid with --runner docker")
    if args.numa_node is not None and args.numa_node < 0:
        parser.error("--numa-node must be >= 0")
    if args.cpuset_mems is not None and args.runner != "docker":
        parser.error("--cpuset-mems is only valid with --runner docker")
    if args.episodes_per_sandbox < 1:
        parser.error("--episodes-per-sandbox must be >= 1")
    if args.episodes_per_sandbox > 1 and args.runner != "rlp":
        parser.error("--episodes-per-sandbox > 1 is only supported with --runner rlp")
    if args.hold_then_exec and args.runner != "rlp":
        parser.error("--hold-then-exec is only valid with --runner rlp")
    if args.n < 1:
        parser.error("--n must be >= 1")

    rlimit = require_nofile(max(args.levels))
    print(
        f"rlimit_nofile soft={rlimit['nofile_soft']} "
        f"hard={rlimit['nofile_hard']} "
        f"before={rlimit['nofile_soft_before']} "
        f"raised={rlimit['nofile_raised']}"
    )

    spec = get_benchmark(args.benchmark)
    if args.snapshot:
        artifact = args.snapshot
    elif args.runner == "rlp":
        artifact = spec.boot_image_for_rlp(args.target)
    else:
        artifact = spec.artifact_name
    output = (
        Path(args.output)
        if args.output
        else default_output_path(
            args.runner,
            args.n,
            benchmark=args.benchmark,
            target=args.target,
            host_cpus=args.host_cpus,
            rlp_cpu=args.rlp_cpu if args.runner == "rlp" else None,
            rlp_cpu_max=args.rlp_cpu_max if args.runner == "rlp" else None,
            numa_node=args.numa_node,
            cpuset_mems=args.cpuset_mems,
        )
    )
    print(
        f"benchmark={args.benchmark} runner={args.runner} "
        f"target={args.target!r} artifact={artifact!r} "
        f"episodes_per_sandbox={args.episodes_per_sandbox} "
        f"rlp_cpu={args.rlp_cpu!r} rlp_cpu_max={args.rlp_cpu_max!r} "
        f"rlp_memory={args.rlp_memory!r} rlp_memory_max={args.rlp_memory_max!r} "
        f"rlp_disk={args.rlp_disk!r} hold_then_exec={args.hold_then_exec} "
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
        "host_cpus": args.host_cpus,
        "numa_node": args.numa_node,
        "rlp_cpu": args.rlp_cpu if args.runner == "rlp" else None,
        "rlp_cpu_max": args.rlp_cpu_max if args.runner == "rlp" else None,
        "rlp_memory": args.rlp_memory if args.runner == "rlp" else None,
        "rlp_memory_max": args.rlp_memory_max if args.runner == "rlp" else None,
        "rlp_disk": args.rlp_disk if args.runner == "rlp" else None,
        "hold_then_exec": bool(args.hold_then_exec),
        "rlimit_nofile": rlimit,
    }
    if args.runner == "rlp":
        meta["rlp_client_tuning"] = rlp_client_tuning_settings()
        meta["client_host"] = socket.gethostname()

    runner = build_runner(args)
    meta["env"] = probe_runner_env(runner, runner_name=args.runner)
    limits = getattr(runner, "docker_limits_meta", None)
    if callable(limits):
        meta.update(limits())
    print(f"env={json.dumps(meta['env'], separators=(',', ':'))}")

    if args.hold_then_exec:
        run_hold_suite(
            levels=args.levels,
            n=args.n,
            seed=args.seed,
            output=output,
            runner=runner,
            meta=meta,
            job_seed_mod=1,
        )
        return

    run_suite(
        levels=args.levels,
        n=args.n,
        seed=args.seed,
        output=output,
        run_worker=runner_as_worker(runner, args),
        meta=meta,
        job_seed_mod=1,
    )


if __name__ == "__main__":
    main()

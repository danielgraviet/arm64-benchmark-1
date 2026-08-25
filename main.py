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
import json
import socket
from pathlib import Path

from harness.benchmarks import BENCHMARK_IDS, TBENCH, get_benchmark
from harness.common import run_hold_suite, run_suite
from harness.paths import default_output_path
from harness.rlp_client_tuning import settings as rlp_client_tuning_settings
from harness.runners import (
    DAYTONA_FAMILY,
    RUNNERS,
    build_runner,
    probe_runner_env,
    runner_as_worker,
)
from harness.runners.daytona import default_daytona_snapshot
from harness.runners.harbor import HarborRunner, run_harbor_suite


def main() -> None:
    parser = argparse.ArgumentParser(description="Vera concurrency harness")
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=BENCHMARK_IDS,
        help="Workload package (agent|analytics|rl|evals|media|disk|tbench)",
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
            "Episodes to exec per sandbox before delete (daytona/daytona-vm/rlp). "
            "Default 1 = Chart B density. Use E>=8 for Chart A warm chip runs."
        ),
    )
    parser.add_argument(
        "--output",
        type=str,
        default=None,
        help=(
            "Override JSONL path (default: data/<benchmark>/<series>/"
            "concurrency_<ts>_n<n>.jsonl; RLP uses rlp-x86 / rlp-phoenix / "
            "rlp-arm64 / rlp-vera)"
        ),
    )
    parser.add_argument(
        "--snapshot",
        type=str,
        default=None,
        help=(
            "Override snapshot/template name, or a registry image ref for RLP "
            "(e.g. dtgraviet/vera-agent-benchmark-rl:latest)"
        ),
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
            "Region/target for daytona/daytona-vm/rlp/harbor "
            "(e.g. arm64-test-1, us-phoenix-1, vera). "
            "Harbor forwards as DAYTONA_TARGET until the region flag is frozen."
        ),
    )
    parser.add_argument(
        "--toolbox-url",
        type=str,
        default=None,
        help="Override RLP toolbox proxy URL (defaults from --target map or env)",
    )
    parser.add_argument(
        "--rlp-cpu",
        type=float,
        default=1.0,
        help=(
            "RLP create Resources.cpu guarantee (default 1). Use 0.125 with "
            "--rlp-cpu-max for burstable density. Results go under "
            "data/<bench>/rlp-<cell>-c0p125/ when not 1.0."
        ),
    )
    parser.add_argument(
        "--rlp-cpu-max",
        type=float,
        default=None,
        help=(
            "RLP Resources.cpu_max burst cap in vCPUs (e.g. 1). Omits "
            "mode=dedicated so the cell does not reserve a full vCPU. "
            "Requires eng rlp-sdk Resources.cpu_max."
        ),
    )
    parser.add_argument(
        "--rlp-memory",
        type=float,
        default=None,
        help="RLP Resources.memory GiB guarantee (default: benchmark docker_memory)",
    )
    parser.add_argument(
        "--rlp-memory-max",
        type=float,
        default=None,
        help="RLP Resources.memory_max GiB burst cap (e.g. 4)",
    )
    parser.add_argument(
        "--rlp-disk",
        type=float,
        default=None,
        help="RLP Resources.disk GiB (default: max(2, memory))",
    )
    parser.add_argument(
        "--host-cpus",
        type=int,
        default=None,
        help=(
            "Pin Docker/EC2 workers to cpuset 0..(N-1) so high-concurrency "
            "runs match an N-core control host (e.g. --host-cpus 32). "
            "Does not pin NUMA memory — use --numa-node for that. "
            "Results go under data/<bench>/docker-cN/."
        ),
    )
    parser.add_argument(
        "--numa-node",
        type=int,
        default=None,
        help=(
            "Docker only, Linux host: pin every worker to NUMA node N "
            "(--cpuset-cpus from sysfs + --cpuset-mems=N). First socket is "
            "usually 0. Results go under data/<bench>/docker-numaN/."
        ),
    )
    parser.add_argument(
        "--cpuset-mems",
        type=str,
        default=None,
        help=(
            "Docker only: pass-through --cpuset-mems (e.g. 0). Combine with "
            "--host-cpus if you already know 0..(N-1) is that socket. "
            "Ignored when --numa-node is set."
        ),
    )
    parser.add_argument(
        "--hold-then-exec",
        action="store_true",
        help=(
            "RLP only: pre-create a fleet of C sandboxes, wait until all "
            "started, then exec -E times, then delete. Isolates chip "
            "duration_ms and exec-wave throughput from create/delete churn. "
            "JSONL summaries include create_wall_s / exec_wall_s; "
            "throughput_per_sec is episodes / exec wall."
        ),
    )
    args = parser.parse_args()

    if args.toolbox_url and args.runner != "rlp":
        parser.error("--toolbox-url is only valid with --runner rlp")
    if args.target and args.runner not in (*DAYTONA_FAMILY, "rlp", "harbor"):
        parser.error(
            "--target is only valid with --runner daytona, daytona-vm, "
            "daytona-vm-hot, rlp, or harbor"
        )
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
        parser.error(
            "--rlp-cpu-max / --rlp-memory / --rlp-memory-max / --rlp-disk "
            "are only valid with --runner rlp"
        )
    if args.rlp_cpu_max is not None and args.rlp_cpu_max < args.rlp_cpu:
        parser.error("--rlp-cpu-max must be >= --rlp-cpu")
    if (
        args.rlp_memory_max is not None
        and args.rlp_memory is not None
        and args.rlp_memory_max < args.rlp_memory
    ):
        parser.error("--rlp-memory-max must be >= --rlp-memory")
    if args.host_cpus is not None and args.runner not in ("docker", "ec2"):
        parser.error("--host-cpus is only valid with --runner docker or ec2")
    if args.host_cpus is not None and args.host_cpus < 1:
        parser.error("--host-cpus must be >= 1")
    if args.numa_node is not None and args.runner != "docker":
        parser.error("--numa-node is only valid with --runner docker")
    if args.numa_node is not None and args.numa_node < 0:
        parser.error("--numa-node must be >= 0")
    if args.numa_node is not None and (
        args.host_cpus is not None or args.cpuset_mems is not None
    ):
        parser.error("--numa-node cannot be combined with --host-cpus or --cpuset-mems")
    if args.cpuset_mems is not None and args.runner != "docker":
        parser.error("--cpuset-mems is only valid with --runner docker")
    if args.episodes_per_sandbox < 1:
        parser.error("--episodes-per-sandbox must be >= 1")
    if args.episodes_per_sandbox > 1 and args.runner not in (*DAYTONA_FAMILY, "rlp"):
        parser.error(
            "--episodes-per-sandbox > 1 is only supported with "
            "--runner daytona, daytona-vm, daytona-vm-hot, or rlp"
        )
    if args.hold_then_exec and args.runner != "rlp":
        parser.error("--hold-then-exec is only valid with --runner rlp")
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
    if args.snapshot:
        artifact = args.snapshot
    elif args.runner == "rlp":
        artifact = spec.boot_image_for_rlp(args.target)
    elif args.runner in DAYTONA_FAMILY:
        if args.runner == "daytona-vm-hot":
            kind, boot = "vm", "hot"
        elif args.runner == "daytona-vm":
            kind, boot = "vm", "cold"
        else:
            kind, boot = "container", "cold"
        if args.target:
            base = spec.artifact_for_target(args.target)
            artifact = f"{base}-hot" if boot == "hot" else base
        else:
            artifact = default_daytona_snapshot(spec, kind, vm_boot=boot)
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
        f"host_cpus={args.host_cpus!r} numa_node={args.numa_node!r} "
        f"cpuset_mems={args.cpuset_mems!r} rlp_cpu={args.rlp_cpu!r} "
        f"rlp_cpu_max={args.rlp_cpu_max!r} rlp_memory={args.rlp_memory!r} "
        f"rlp_memory_max={args.rlp_memory_max!r} rlp_disk={args.rlp_disk!r} "
        f"hold_then_exec={args.hold_then_exec} output={output}"
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
    }
    if args.runner == "rlp":
        meta["rlp_client_tuning"] = rlp_client_tuning_settings()
        meta["client_host"] = socket.gethostname()
    if args.benchmark == "evals":
        meta["eval_task_id"] = "log-surgery"

    if args.runner == "harbor":
        meta["env"] = probe_runner_env(None, runner_name="harbor")
        print(f"env={json.dumps(meta['env'], separators=(',', ':'))}")
        run_harbor_suite(
            levels=args.levels,
            task_limit=args.n,
            seed=args.seed,
            output=output,
            runner=HarborRunner(target=args.target),
            meta=meta,
        )
        return

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

"""Runner registry. This pack is RLP (on-node) plus Docker smoke."""

from __future__ import annotations

import argparse
from collections.abc import Callable
from typing import Any, Protocol

from harness.benchmarks import get_benchmark
from harness.env_probe import host_env, skipped_env
from harness.runners.docker import DockerRunner
from harness.runners.rlp import RlpRunner

RunWorker = Callable[[int, int], list[dict[str, Any]]]


class SupportsProbeEnv(Protocol):
    def probe_env(self) -> dict[str, Any]: ...


def _as_worker(run_one: Callable[[int, int], dict[str, Any]]) -> RunWorker:
    def _worker(n: int, seed: int) -> list[dict[str, Any]]:
        return [run_one(n, seed)]

    return _worker


def build_runner(args: argparse.Namespace) -> Any:
    spec = get_benchmark(args.benchmark)
    host_cpus = getattr(args, "host_cpus", None)
    if args.runner == "docker":
        return DockerRunner(
            spec,
            host_cpus=host_cpus,
            cpuset_mems=getattr(args, "cpuset_mems", None),
            numa_node=getattr(args, "numa_node", None),
        )
    if args.runner == "rlp":
        return RlpRunner(
            spec=spec,
            snapshot=args.snapshot or spec.boot_image_for_rlp(args.target),
            exec_timeout_s=args.exec_timeout,
            target=args.target,
            toolbox_url=args.toolbox_url,
            episodes_per_sandbox=args.episodes_per_sandbox,
            cpu=getattr(args, "rlp_cpu", 1.0),
            cpu_max=getattr(args, "rlp_cpu_max", None),
            memory=getattr(args, "rlp_memory", None),
            memory_max=getattr(args, "rlp_memory_max", None),
            disk=getattr(args, "rlp_disk", None),
        )
    raise ValueError(f"Unknown runner: {args.runner}")


def runner_as_worker(runner: Any, args: argparse.Namespace) -> RunWorker:
    if args.runner == "rlp":
        return runner.run_episodes
    return _as_worker(runner.run_one)


def probe_runner_env(runner: Any | None, *, runner_name: str) -> dict[str, Any]:
    host = host_env()
    if runner is None:
        return skipped_env(host)
    probe = getattr(runner, "probe_env", None)
    if not callable(probe):
        return skipped_env(host)
    return probe()


def build_run_one(args: argparse.Namespace) -> RunWorker:
    runner = build_runner(args)
    return runner_as_worker(runner, args)


build_run_worker = build_run_one

RUNNERS = ("docker", "rlp")

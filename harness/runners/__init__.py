"""Runner registry / factory.

Each backend registers a factory that turns CLI args into a runner instance.
``build_run_worker`` wraps that runner for the concurrency suite. Daytona/RLP
support ``--episodes-per-sandbox`` (sandbox reuse).
"""

from __future__ import annotations

import argparse
from collections.abc import Callable
from typing import Any, Protocol

from harness.benchmarks import get_benchmark
from harness.env_probe import host_env, skipped_env
from harness.runners.daytona import DaytonaRunner, default_daytona_snapshot
from harness.runners.docker import DockerRunner
from harness.runners.e2b import E2bRunner
from harness.runners.ec2 import Ec2Runner
from harness.runners.rlp import RlpRunner

RunWorker = Callable[[int, int], list[dict[str, Any]]]

DAYTONA_FAMILY = frozenset({"daytona", "daytona-vm", "daytona-vm-hot"})


class SupportsProbeEnv(Protocol):
    def probe_env(self) -> dict[str, Any]: ...


def _as_worker(run_one: Callable[[int, int], dict[str, Any]]) -> RunWorker:
    def _worker(n: int, seed: int) -> list[dict[str, Any]]:
        return [run_one(n, seed)]

    return _worker


def build_runner(args: argparse.Namespace) -> Any:
    """Construct the backend runner once (shared by env probe + workers)."""
    spec = get_benchmark(args.benchmark)
    host_cpus = getattr(args, "host_cpus", None)
    if args.runner == "docker":
        return DockerRunner(
            spec,
            host_cpus=host_cpus,
            cpuset_mems=getattr(args, "cpuset_mems", None),
            numa_node=getattr(args, "numa_node", None),
        )
    if args.runner == "ec2":
        return Ec2Runner(spec, host_cpus=host_cpus)
    if args.runner in DAYTONA_FAMILY:
        if args.runner == "daytona":
            kind, boot = "container", "cold"
        elif args.runner == "daytona-vm-hot":
            kind, boot = "vm", "hot"
        else:
            kind, boot = "vm", "cold"
        if args.snapshot:
            snap = args.snapshot
        elif args.target:
            # Per-target snap names (e.g. us-east-1-arm Graviton5 rebuilds).
            base = spec.artifact_for_target(args.target)
            snap = f"{base}-hot" if boot == "hot" else base
        else:
            snap = default_daytona_snapshot(spec, kind, vm_boot=boot)
        return DaytonaRunner(
            spec=spec,
            snapshot=snap,
            exec_timeout_s=args.exec_timeout,
            target=args.target,
            episodes_per_sandbox=args.episodes_per_sandbox,
            sandbox_kind=kind,
            vm_boot=boot,
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
    if args.runner == "e2b":
        return E2bRunner(
            spec=spec,
            template=args.snapshot or spec.artifact_name,
            exec_timeout_s=args.exec_timeout,
        )
    if args.runner == "harbor":
        return None
    raise ValueError(f"Unknown runner: {args.runner}")


def runner_as_worker(runner: Any, args: argparse.Namespace) -> RunWorker:
    if args.runner in DAYTONA_FAMILY or args.runner == "rlp":
        return runner.run_episodes
    if args.runner == "harbor":

        def _worker(_n: int, _seed: int) -> list[dict[str, Any]]:
            raise RuntimeError(
                "Harbor runner must use run_harbor_suite (one job per --levels value)."
            )

        return _worker
    return _as_worker(runner.run_one)


def probe_runner_env(runner: Any | None, *, runner_name: str) -> dict[str, Any]:
    """One-shot env probe; Harbor / missing probe → skipped with host fields."""
    host = host_env()
    if runner is None or runner_name == "harbor":
        return skipped_env(host)
    probe = getattr(runner, "probe_env", None)
    if not callable(probe):
        return skipped_env(host)
    return probe()


def build_run_one(args: argparse.Namespace) -> RunWorker:
    """Return a worker that yields one or more episode records per call."""
    runner = build_runner(args)
    return runner_as_worker(runner, args)


# Back-compat name used by main.py
build_run_worker = build_run_one

RUNNERS = (
    "docker",
    "daytona",
    "daytona-vm",
    "daytona-vm-hot",
    "rlp",
    "e2b",
    "ec2",
    "harbor",
)

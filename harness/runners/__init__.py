"""Runner registry / factory.

Each backend registers a factory that turns CLI args into a ``run_worker``
callable returning ``list[dict]`` (one dict per episode). Single-shot runners
wrap ``run_one`` as a one-element list. Daytona/RLP support
``--episodes-per-sandbox`` (sandbox reuse).
"""

from __future__ import annotations

import argparse
from collections.abc import Callable
from typing import Any

from harness.benchmarks import get_benchmark
from harness.runners.daytona import DaytonaRunner
from harness.runners.docker import DockerRunner
from harness.runners.e2b import E2bRunner
from harness.runners.ec2 import make_run_one as ec2_make_run_one
from harness.runners.rlp import RlpRunner

RunWorker = Callable[[int, int], list[dict[str, Any]]]
RunnerFactory = Callable[[argparse.Namespace], RunWorker]


def _as_worker(run_one: Callable[[int, int], dict[str, Any]]) -> RunWorker:
    def _worker(n: int, seed: int) -> list[dict[str, Any]]:
        return [run_one(n, seed)]

    return _worker


def _docker(args: argparse.Namespace) -> RunWorker:
    return _as_worker(DockerRunner(get_benchmark(args.benchmark)).run_one)


def _ec2(args: argparse.Namespace) -> RunWorker:
    return _as_worker(ec2_make_run_one(get_benchmark(args.benchmark)))


def _daytona(args: argparse.Namespace) -> RunWorker:
    spec = get_benchmark(args.benchmark)
    runner = DaytonaRunner(
        spec=spec,
        snapshot=args.snapshot or spec.artifact_name,
        exec_timeout_s=args.exec_timeout,
        target=args.target,
        episodes_per_sandbox=args.episodes_per_sandbox,
    )
    return runner.run_episodes


def _rlp(args: argparse.Namespace) -> RunWorker:
    spec = get_benchmark(args.benchmark)
    runner = RlpRunner(
        spec=spec,
        snapshot=args.snapshot or spec.artifact_for_target(args.target),
        exec_timeout_s=args.exec_timeout,
        target=args.target,
        toolbox_url=args.toolbox_url,
        episodes_per_sandbox=args.episodes_per_sandbox,
    )
    return runner.run_episodes


def _e2b(args: argparse.Namespace) -> RunWorker:
    spec = get_benchmark(args.benchmark)
    return _as_worker(
        E2bRunner(
            spec=spec,
            template=args.snapshot or spec.artifact_name,
            exec_timeout_s=args.exec_timeout,
        ).run_one
    )


RUNNER_FACTORIES: dict[str, RunnerFactory] = {
    "docker": _docker,
    "daytona": _daytona,
    "rlp": _rlp,
    "e2b": _e2b,
    "ec2": _ec2,
}

RUNNERS = tuple(RUNNER_FACTORIES)


def build_run_one(args: argparse.Namespace) -> RunWorker:
    """Return a worker that yields one or more episode records per call."""
    try:
        factory = RUNNER_FACTORIES[args.runner]
    except KeyError as exc:
        raise ValueError(f"Unknown runner: {args.runner}") from exc
    return factory(args)


# Back-compat name used by main.py
build_run_worker = build_run_one

"""Runner registry / factory.

Each backend registers a factory that turns CLI args into a ``run_one(n, seed)``
callable. Add a new runner by:

1. Implementing ``run_one`` (module function or class method)
2. Adding a one-line factory in ``RUNNER_FACTORIES``

Benchmarks are selected via ``--benchmark`` and resolved before the runner
factory runs (see ``harness.benchmarks``).
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

RunOne = Callable[[int, int], dict[str, Any]]
RunnerFactory = Callable[[argparse.Namespace], RunOne]


def _docker(args: argparse.Namespace) -> RunOne:
    return DockerRunner(get_benchmark(args.benchmark)).run_one


def _ec2(args: argparse.Namespace) -> RunOne:
    return ec2_make_run_one(get_benchmark(args.benchmark))


def _daytona(args: argparse.Namespace) -> RunOne:
    spec = get_benchmark(args.benchmark)
    return DaytonaRunner(
        spec=spec,
        snapshot=args.snapshot or spec.artifact_name,
        exec_timeout_s=args.exec_timeout,
        target=args.target,
    ).run_one


def _rlp(args: argparse.Namespace) -> RunOne:
    spec = get_benchmark(args.benchmark)
    return RlpRunner(
        spec=spec,
        snapshot=args.snapshot or spec.artifact_name,
        exec_timeout_s=args.exec_timeout,
        target=args.target,
        toolbox_url=args.toolbox_url,
    ).run_one


def _e2b(args: argparse.Namespace) -> RunOne:
    spec = get_benchmark(args.benchmark)
    return E2bRunner(
        spec=spec,
        template=args.snapshot or spec.artifact_name,
        exec_timeout_s=args.exec_timeout,
    ).run_one


RUNNER_FACTORIES: dict[str, RunnerFactory] = {
    "docker": _docker,
    "daytona": _daytona,
    "rlp": _rlp,
    "e2b": _e2b,
    "ec2": _ec2,
}

RUNNERS = tuple(RUNNER_FACTORIES)


def build_run_one(args: argparse.Namespace) -> RunOne:
    try:
        factory = RUNNER_FACTORIES[args.runner]
    except KeyError as exc:
        raise ValueError(f"Unknown runner: {args.runner}") from exc
    return factory(args)

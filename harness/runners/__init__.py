"""Runner registry / factory.

Each backend registers a factory that turns CLI args into a ``run_one(n, seed)``
callable. Add a new runner by:

1. Implementing ``run_one`` (module function or class method)
2. Adding a one-line factory in ``RUNNER_FACTORIES``
"""

from __future__ import annotations

import argparse
from collections.abc import Callable
from typing import Any

from harness.runners import docker, ec2
from harness.runners.daytona import DaytonaRunner
from harness.runners.e2b import E2bRunner
from harness.runners.rlp import RlpRunner

RunOne = Callable[[int, int], dict[str, Any]]
RunnerFactory = Callable[[argparse.Namespace], RunOne]


def _docker(_args: argparse.Namespace) -> RunOne:
    return docker.run_one


def _ec2(_args: argparse.Namespace) -> RunOne:
    return ec2.run_one


def _daytona(args: argparse.Namespace) -> RunOne:
    return DaytonaRunner(
        snapshot=args.snapshot,
        exec_timeout_s=args.exec_timeout,
        target=args.target,
    ).run_one


def _rlp(args: argparse.Namespace) -> RunOne:
    return RlpRunner(
        snapshot=args.snapshot,
        exec_timeout_s=args.exec_timeout,
        target=args.target,
        toolbox_url=args.toolbox_url,
    ).run_one


def _e2b(args: argparse.Namespace) -> RunOne:
    return E2bRunner(
        template=args.snapshot,
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

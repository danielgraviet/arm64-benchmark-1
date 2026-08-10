"""EC2-labeled runner: same Docker workers, different data/ folder via CLI."""

from __future__ import annotations

from typing import Any

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.runners.docker import DockerRunner


def make_run_one(spec: BenchmarkSpec = AGENT):
    return DockerRunner(spec).run_one


def run_one(n: int, seed: int) -> dict[str, Any]:
    return DockerRunner(AGENT).run_one(n, seed)

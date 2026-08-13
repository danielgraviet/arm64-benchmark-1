"""EC2-labeled runner: same Docker workers, different data/ folder via CLI."""

from __future__ import annotations

from typing import Any

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.runners.docker import DockerRunner


class Ec2Runner(DockerRunner):
    """Same as DockerRunner; probe_env inherits docker probe."""

    def probe_env(self) -> dict[str, Any]:
        env = super().probe_env()
        # Relabel so meta.env.probe reflects the CLI runner name.
        if env.get("probe") == "docker":
            env = {**env, "probe": "ec2"}
        return env


def make_run_one(spec: BenchmarkSpec = AGENT):
    return Ec2Runner(spec).run_one


def run_one(n: int, seed: int) -> dict[str, Any]:
    return Ec2Runner(AGENT).run_one(n, seed)

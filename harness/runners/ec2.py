"""EC2-labeled runner: same Docker workers, different data/ folder via CLI."""

from __future__ import annotations

from typing import Any

from harness.runners import docker


def run_one(n: int, seed: int) -> dict[str, Any]:
    return docker.run_one(n, seed)

"""Local Docker worker backend."""

from __future__ import annotations

import json
import subprocess
import time
from typing import Any

from harness.benchmarks import AGENT, BenchmarkSpec


class DockerRunner:
    def __init__(self, spec: BenchmarkSpec = AGENT) -> None:
        self._spec = spec
        print(f"docker client: image={spec.docker_image!r}")

    def run_one(self, n: int, seed: int) -> dict[str, Any]:
        start = time.monotonic()
        result = subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "--cpus=1",
                f"--memory={self._spec.docker_memory}",
                self._spec.docker_image,
                *self._spec.agent_argv(n, seed),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        record: dict[str, Any] = {
            "latency_ms": (time.monotonic() - start) * 1000,
            "exit_code": result.returncode,
            "benchmark": self._spec.id,
        }
        if result.returncode == 0:
            try:
                payload = json.loads(result.stdout.strip())
                record["checksum"] = payload.get("checksum")
                record["duration_ms"] = payload.get("duration_ms")
            except json.JSONDecodeError:
                record["error"] = "invalid_json_output"
                record["stdout"] = result.stdout
        else:
            record["stderr"] = result.stderr
        return record


def run_one(n: int, seed: int) -> dict[str, Any]:
    """Back-compat module-level entry (agent image)."""
    return DockerRunner(AGENT).run_one(n, seed)
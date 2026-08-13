"""Local Docker worker backend."""

from __future__ import annotations

import json
import subprocess
import time
from typing import Any

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.env_probe import PROBE_PY, failed_env, host_env, merge_env, parse_probe_stdout


class DockerRunner:
    def __init__(self, spec: BenchmarkSpec = AGENT) -> None:
        self._spec = spec
        print(f"docker client: image={spec.docker_image!r}")

    def probe_env(self) -> dict[str, Any]:
        host = host_env()
        try:
            result = subprocess.run(
                [
                    "docker",
                    "run",
                    "--rm",
                    "--entrypoint",
                    "python",
                    self._spec.docker_image,
                    "-c",
                    PROBE_PY,
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=120,
            )
            if result.returncode != 0:
                err = (result.stderr or result.stdout or "").strip() or f"exit {result.returncode}"
                print(f"warning: docker env probe failed: {err[:200]}")
                return failed_env(host, probe="docker", error=err[:500])
            remote = parse_probe_stdout(result.stdout)
            return merge_env(host, remote, probe="docker")
        except Exception as exc:  # noqa: BLE001
            print(f"warning: docker env probe failed: {exc}")
            return failed_env(host, probe="docker", error=str(exc))

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

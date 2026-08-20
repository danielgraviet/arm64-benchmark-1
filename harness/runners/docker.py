"""Local Docker worker backend."""

from __future__ import annotations

import json
import subprocess
import time
from typing import Any

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.common import apply_workload_payload
from harness.env_probe import PROBE_PY, failed_env, host_env, merge_env, parse_probe_stdout


def cpuset_range(host_cpus: int) -> str:
    """``0-(n-1)`` for Docker ``--cpuset-cpus`` (n >= 1)."""
    if host_cpus < 1:
        raise ValueError(f"host_cpus must be >= 1, got {host_cpus}")
    if host_cpus == 1:
        return "0"
    return f"0-{host_cpus - 1}"


class DockerRunner:
    def __init__(
        self,
        spec: BenchmarkSpec = AGENT,
        *,
        cpus: str = "1",
        cpuset_cpus: str | None = None,
        host_cpus: int | None = None,
    ) -> None:
        self._spec = spec
        self._cpus = cpus
        if host_cpus is not None and cpuset_cpus is not None:
            raise ValueError("pass only one of host_cpus or cpuset_cpus")
        if host_cpus is not None:
            self._host_cpus = host_cpus
            self._cpuset_cpus = cpuset_range(host_cpus)
        else:
            self._host_cpus = None
            self._cpuset_cpus = cpuset_cpus
        extra = f" cpuset={self._cpuset_cpus!r}" if self._cpuset_cpus else ""
        print(
            f"docker client: image={spec.docker_image!r} "
            f"cpus={self._cpus!r}{extra}"
        )

    def docker_limits_meta(self) -> dict[str, Any]:
        """Fields to merge into JSONL meta for apples-to-apples labeling."""
        out: dict[str, Any] = {
            "docker_cpus": self._cpus,
            "docker_cpuset_cpus": self._cpuset_cpus,
            "host_cpus": self._host_cpus,
        }
        return out

    def _run_args(self, *tail: str) -> list[str]:
        cmd = [
            "docker",
            "run",
            "--rm",
            f"--cpus={self._cpus}",
            f"--memory={self._spec.docker_memory}",
        ]
        if self._cpuset_cpus:
            cmd.append(f"--cpuset-cpus={self._cpuset_cpus}")
        cmd.extend(tail)
        return cmd

    def probe_env(self) -> dict[str, Any]:
        host = host_env()
        try:
            result = subprocess.run(
                self._run_args(
                    "--entrypoint",
                    "python",
                    self._spec.docker_image,
                    "-c",
                    PROBE_PY,
                ),
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
            env = merge_env(host, remote, probe="docker")
            # Label the *cap* we imposed (os.cpu_count inside may still see all cores).
            if self._host_cpus is not None:
                env = {
                    **env,
                    "host_cpus_cap": self._host_cpus,
                    "docker_cpuset_cpus": self._cpuset_cpus,
                }
            elif self._cpuset_cpus:
                env = {**env, "docker_cpuset_cpus": self._cpuset_cpus}
            return env
        except Exception as exc:  # noqa: BLE001
            print(f"warning: docker env probe failed: {exc}")
            return failed_env(host, probe="docker", error=str(exc))

    def run_one(self, n: int, seed: int) -> dict[str, Any]:
        start = time.monotonic()
        result = subprocess.run(
            self._run_args(
                self._spec.docker_image,
                *self._spec.agent_argv(n, seed),
            ),
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
                apply_workload_payload(record, payload)
            except json.JSONDecodeError:
                record["error"] = "invalid_json_output"
                record["stdout"] = result.stdout
        else:
            record["stderr"] = result.stderr
        return record


def run_one(n: int, seed: int) -> dict[str, Any]:
    """Back-compat module-level entry (agent image)."""
    return DockerRunner(AGENT).run_one(n, seed)

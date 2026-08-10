"""Daytona sandbox worker backend (official daytona SDK)."""

from __future__ import annotations

import json
import time
from typing import Any

from daytona import CreateSandboxFromSnapshotParams, Daytona, DaytonaConfig
from dotenv import load_dotenv

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.paths import ROOT

APP_DIR = "/home/daytona/app"
DEFAULT_EXEC_TIMEOUT_S = 600


class DaytonaRunner:
    def __init__(
        self,
        *,
        spec: BenchmarkSpec = AGENT,
        snapshot: str | None = None,
        exec_timeout_s: int = DEFAULT_EXEC_TIMEOUT_S,
        target: str | None = None,
    ) -> None:
        load_dotenv(ROOT / ".env")
        self._spec = spec
        self._snapshot = snapshot or spec.artifact_name
        self._exec_timeout_s = exec_timeout_s
        self._target = target
        self._run_env = spec.run_env(APP_DIR)
        self._agent_cmd = spec.agent_command()
        config = DaytonaConfig(connection_pool_maxsize=None)
        if target:
            config = DaytonaConfig(connection_pool_maxsize=None, target=target)
        self._client = Daytona(config)
        print(
            f"daytona client: target={target!r} snapshot={self._snapshot!r} "
            f"benchmark={spec.id!r}"
        )

    def run_one(self, n: int, seed: int) -> dict[str, Any]:
        start = time.monotonic()
        sandbox = None
        try:
            sandbox = self._client.create(
                CreateSandboxFromSnapshotParams(
                    snapshot=self._snapshot,
                    ephemeral=True,
                    language="python",
                ),
                timeout=120,
            )
            argv = " ".join(self._spec.agent_argv(n, seed))
            response = sandbox.process.exec(
                f"{self._agent_cmd} {argv}",
                cwd=APP_DIR,
                env=self._run_env,
                timeout=self._exec_timeout_s,
            )
            exit_code = int(response.exit_code or 0)
            stdout = (response.result or "").strip()

            record: dict[str, Any] = {
                "latency_ms": (time.monotonic() - start) * 1000,
                "exit_code": exit_code,
                "sandbox_id": sandbox.id,
                "target": self._target,
                "benchmark": self._spec.id,
            }
            if exit_code == 0:
                try:
                    payload = json.loads(stdout)
                    record["checksum"] = payload.get("checksum")
                    record["duration_ms"] = payload.get("duration_ms")
                except json.JSONDecodeError:
                    record["error"] = "invalid_json_output"
                    record["stdout"] = stdout
            else:
                record["stderr"] = stdout
            return record
        except Exception as exc:  # noqa: BLE001
            return {
                "latency_ms": (time.monotonic() - start) * 1000,
                "exit_code": -1,
                "error": f"{type(exc).__name__}: {exc}",
                "target": self._target,
                "benchmark": self._spec.id,
            }
        finally:
            if sandbox is not None:
                try:
                    self._client.delete(sandbox)
                except Exception:  # noqa: BLE001, S110
                    pass

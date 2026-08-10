"""Daytona sandbox worker backend (official daytona SDK)."""

from __future__ import annotations

import json
import time
from typing import Any

from daytona import CreateSandboxFromSnapshotParams, Daytona, DaytonaConfig
from dotenv import load_dotenv

from harness.paths import ROOT

SNAPSHOT_NAME = "vera-agent-benchmark"
APP_DIR = "/home/daytona/app"
DEFAULT_EXEC_TIMEOUT_S = 600
RUN_ENV = {
    "PYTHONPATH": f"{APP_DIR}/workload/repos/sqlite-utils",
    "PYTHONHASHSEED": "0",
}
AGENT_CMD = "python -m workload.agent"


class DaytonaRunner:
    def __init__(
        self,
        *,
        snapshot: str = SNAPSHOT_NAME,
        exec_timeout_s: int = DEFAULT_EXEC_TIMEOUT_S,
    ) -> None:
        load_dotenv(ROOT / ".env")
        self._snapshot = snapshot
        self._exec_timeout_s = exec_timeout_s
        self._client = Daytona(DaytonaConfig(connection_pool_maxsize=None))

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
            response = sandbox.process.exec(
                f"{AGENT_CMD} --n {n} --seed {seed}",
                cwd=APP_DIR,
                env=RUN_ENV,
                timeout=self._exec_timeout_s,
            )
            exit_code = int(response.exit_code or 0)
            stdout = (response.result or "").strip()

            record: dict[str, Any] = {
                "latency_ms": (time.monotonic() - start) * 1000,
                "exit_code": exit_code,
                "sandbox_id": sandbox.id,
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
            }
        finally:
            if sandbox is not None:
                try:
                    self._client.delete(sandbox)
                except Exception:  # noqa: BLE001, S110
                    pass

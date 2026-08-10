"""E2B sandbox worker backend.

Requires ``E2B_API_KEY`` in the environment (or ``.env``).

Boot from a prebuilt template (default ``vera-agent-benchmark``), built via:

    uv run scripts/build_e2b_template.py
"""

from __future__ import annotations

import json
import time
from typing import Any

from dotenv import load_dotenv
from e2b import CommandExitException, Sandbox

from harness.paths import ROOT

TEMPLATE_NAME = "vera-agent-benchmark"
APP_DIR = "/home/user/app"
VENV_PYTHON = f"{APP_DIR}/.venv/bin/python"
DEFAULT_EXEC_TIMEOUT_S = 600
RUN_ENV = {
    "PATH": f"{APP_DIR}/.venv/bin:/usr/local/bin:/usr/bin:/bin",
    "VIRTUAL_ENV": f"{APP_DIR}/.venv",
    "PYTHONPATH": f"{APP_DIR}/workload/repos/sqlite-utils",
    "PYTHONHASHSEED": "0",
}
# Absolute venv python — E2B command PATH is not always honored the same way
# as a login shell, which previously hit system python (no pytest).
AGENT_CMD = f"{VENV_PYTHON} -m workload.agent"


class E2bRunner:
    def __init__(
        self,
        *,
        template: str = TEMPLATE_NAME,
        exec_timeout_s: int = DEFAULT_EXEC_TIMEOUT_S,
    ) -> None:
        load_dotenv(ROOT / ".env")
        self._template = template
        self._exec_timeout_s = exec_timeout_s
        # Sandbox lifetime must cover create overhead + agent exec.
        self._sandbox_timeout_s = max(exec_timeout_s + 120, 300)
        print(f"e2b client: template={template!r}")

    def run_one(self, n: int, seed: int) -> dict[str, Any]:
        start = time.monotonic()
        sandbox = None
        try:
            sandbox = Sandbox.create(
                template=self._template,
                timeout=self._sandbox_timeout_s,
            )
            try:
                result = sandbox.commands.run(
                    f"{AGENT_CMD} --n {n} --seed {seed}",
                    cwd=APP_DIR,
                    envs=RUN_ENV,
                    timeout=float(self._exec_timeout_s),
                )
                exit_code = int(result.exit_code)
                stdout = (result.stdout or "").strip()
                stderr = (result.stderr or "").strip()
            except CommandExitException as exc:
                exit_code = int(exc.exit_code)
                stdout = (exc.stdout or "").strip()
                stderr = (exc.stderr or "").strip()

            record: dict[str, Any] = {
                "latency_ms": (time.monotonic() - start) * 1000,
                "exit_code": exit_code,
                "sandbox_id": sandbox.sandbox_id,
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
                record["stderr"] = stderr or stdout
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
                    sandbox.kill()
                except Exception:  # noqa: BLE001, S110
                    pass

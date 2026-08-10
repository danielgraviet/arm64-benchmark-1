"""E2B sandbox worker backend.

Requires ``E2B_API_KEY`` in the environment (or ``.env``).

Boot from a prebuilt template (per-benchmark artifact name), built via:

    uv run scripts/build_e2b_template.py --benchmark agent
    uv run scripts/build_e2b_template.py --benchmark analytics
"""

from __future__ import annotations

import json
import time
from typing import Any

from dotenv import load_dotenv
from e2b import CommandExitException, Sandbox

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.paths import ROOT

APP_DIR = "/home/user/app"
VENV_PYTHON = f"{APP_DIR}/.venv/bin/python"
DEFAULT_EXEC_TIMEOUT_S = 600


class E2bRunner:
    def __init__(
        self,
        *,
        spec: BenchmarkSpec = AGENT,
        template: str | None = None,
        exec_timeout_s: int = DEFAULT_EXEC_TIMEOUT_S,
    ) -> None:
        load_dotenv(ROOT / ".env")
        self._spec = spec
        self._template = template or spec.artifact_name
        self._exec_timeout_s = exec_timeout_s
        self._sandbox_timeout_s = max(exec_timeout_s + 120, 300)
        self._run_env = spec.run_env(APP_DIR)
        self._agent_cmd = spec.agent_command(python=VENV_PYTHON)
        print(
            f"e2b client: template={self._template!r} benchmark={spec.id!r}"
        )

    def run_one(self, n: int, seed: int) -> dict[str, Any]:
        start = time.monotonic()
        sandbox = None
        try:
            sandbox = Sandbox.create(
                template=self._template,
                timeout=self._sandbox_timeout_s,
            )
            argv = " ".join(self._spec.agent_argv(n, seed))
            try:
                result = sandbox.commands.run(
                    f"{self._agent_cmd} {argv}",
                    cwd=APP_DIR,
                    envs=self._run_env,
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
                record["stderr"] = stderr or stdout
            return record
        except Exception as exc:  # noqa: BLE001
            return {
                "latency_ms": (time.monotonic() - start) * 1000,
                "exit_code": -1,
                "error": f"{type(exc).__name__}: {exc}",
                "benchmark": self._spec.id,
            }
        finally:
            if sandbox is not None:
                try:
                    sandbox.kill()
                except Exception:  # noqa: BLE001, S110
                    pass

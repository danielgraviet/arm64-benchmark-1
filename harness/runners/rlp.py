"""RLP sandbox worker backend (rlp-sdk Daytona-compatible client)."""

from __future__ import annotations

import json
import threading
import time
from typing import Any

from dotenv import load_dotenv
from rlp import CreateSandboxFromImageParams, Daytona

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.paths import ROOT
from harness.regions import check_sandbox_arch, resolve_rlp_client_config
from harness.rlp_snapshots import resolve_boot_image

APP_DIR = "/home/daytona/app"
DEFAULT_EXEC_TIMEOUT_S = 600


class RlpRunner:
    def __init__(
        self,
        *,
        spec: BenchmarkSpec = AGENT,
        snapshot: str | None = None,
        exec_timeout_s: int = DEFAULT_EXEC_TIMEOUT_S,
        target: str | None = None,
        toolbox_url: str | None = None,
        skip_arch_probe: bool = False,
    ) -> None:
        load_dotenv(ROOT / ".env")
        self._spec = spec
        self._snapshot = snapshot or spec.artifact_name
        self._exec_timeout_s = exec_timeout_s
        self._target = target
        self._run_env = spec.run_env(APP_DIR)
        self._agent_cmd = spec.agent_command()
        config = resolve_rlp_client_config(target, toolbox_url)
        self._client = Daytona(config)
        print(
            f"rlp client: target={config.target!r} toolbox_url={config.toolbox_url!r} "
            f"benchmark={spec.id!r}"
        )

        # Probed once on the first worker sandbox (avoids a spare create on
        # capacity-constrained ARM64 regions).
        self._arch = "unspecified"
        self._arch_probed = skip_arch_probe or not target
        self._arch_lock = threading.Lock()

        self._boot_image = resolve_boot_image(self._client, self._snapshot)
        print(f"rlp boot image: {self._snapshot!r} -> {self._boot_image!r}")

    def run_one(self, n: int, seed: int) -> dict[str, Any]:
        start = time.monotonic()
        sandbox = None
        try:
            sandbox = self._client.create(
                CreateSandboxFromImageParams(image=self._boot_image),
                timeout=120,
            )
            if not self._arch_probed:
                with self._arch_lock:
                    if not self._arch_probed:
                        self._arch = check_sandbox_arch(sandbox, self._target)
                        self._arch_probed = True
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
                "sandbox_id": getattr(sandbox, "id", None),
                "target": self._target,
                "arch": self._arch,
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
                "arch": self._arch,
                "benchmark": self._spec.id,
            }
        finally:
            if sandbox is not None:
                try:
                    self._client.delete(sandbox)
                except Exception:  # noqa: BLE001, S110
                    pass

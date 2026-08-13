"""Daytona sandbox worker backend (official daytona SDK)."""

from __future__ import annotations

import json
import time
from typing import Any

from daytona import CreateSandboxFromSnapshotParams, Daytona, DaytonaConfig
from dotenv import load_dotenv

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.env_probe import failed_env, host_env, merge_env, parse_probe_stdout, probe_shell_command
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
        episodes_per_sandbox: int = 1,
    ) -> None:
        load_dotenv(ROOT / ".env")
        if episodes_per_sandbox < 1:
            raise ValueError("episodes_per_sandbox must be >= 1")
        self._spec = spec
        self._snapshot = snapshot or spec.artifact_name
        self._exec_timeout_s = exec_timeout_s
        self._target = target
        self._episodes_per_sandbox = episodes_per_sandbox
        self._run_env = spec.run_env(APP_DIR)
        self._agent_cmd = spec.agent_command()
        config = DaytonaConfig(connection_pool_maxsize=None)
        if target:
            config = DaytonaConfig(connection_pool_maxsize=None, target=target)
        self._client = Daytona(config)
        print(
            f"daytona client: target={target!r} snapshot={self._snapshot!r} "
            f"benchmark={spec.id!r} episodes_per_sandbox={episodes_per_sandbox}"
        )

    def probe_env(self) -> dict[str, Any]:
        host = host_env()
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
                probe_shell_command(),
                timeout=60,
            )
            exit_code = int(response.exit_code or 0)
            stdout = (response.result or "").strip()
            if exit_code != 0:
                err = stdout or f"exit {exit_code}"
                print(f"warning: daytona env probe failed: {err[:200]}")
                return failed_env(host, probe="daytona", error=err[:500])
            remote = parse_probe_stdout(stdout)
            return merge_env(host, remote, probe="daytona")
        except Exception as exc:  # noqa: BLE001
            print(f"warning: daytona env probe failed: {exc}")
            return failed_env(host, probe="daytona", error=str(exc))
        finally:
            if sandbox is not None:
                try:
                    self._client.delete(sandbox)
                except Exception:  # noqa: BLE001, S110
                    pass

    def run_one(self, n: int, seed: int) -> dict[str, Any]:
        return self.run_episodes(n, seed, episodes=1)[0]

    def run_episodes(
        self, n: int, seed: int, episodes: int | None = None
    ) -> list[dict[str, Any]]:
        """Create once, exec ``episodes`` times, delete once.

        Episode 0 is cold (create + first exec in ``latency_ms``). Later episodes
        are warm (exec-only ``latency_ms``). ``duration_ms`` is always in-container.
        """
        episodes = self._episodes_per_sandbox if episodes is None else episodes
        if episodes < 1:
            raise ValueError("episodes must be >= 1")

        records: list[dict[str, Any]] = []
        sandbox = None
        create_start = time.monotonic()
        try:
            sandbox = self._client.create(
                CreateSandboxFromSnapshotParams(
                    snapshot=self._snapshot,
                    ephemeral=True,
                    language="python",
                ),
                timeout=120,
            )
            sandbox_id = sandbox.id
            argv = " ".join(self._spec.agent_argv(n, seed))
            cmd = f"{self._agent_cmd} {argv}"

            for episode_idx in range(episodes):
                cold = episode_idx == 0
                exec_start = time.monotonic() if not cold else create_start
                try:
                    response = sandbox.process.exec(
                        cmd,
                        cwd=APP_DIR,
                        env=self._run_env,
                        timeout=self._exec_timeout_s,
                    )
                    exit_code = int(response.exit_code or 0)
                    stdout = (response.result or "").strip()
                    record: dict[str, Any] = {
                        "latency_ms": (time.monotonic() - exec_start) * 1000,
                        "exit_code": exit_code,
                        "sandbox_id": sandbox_id,
                        "target": self._target,
                        "benchmark": self._spec.id,
                        "episode_idx": episode_idx,
                        "cold": cold,
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
                    records.append(record)
                except Exception as exc:  # noqa: BLE001
                    records.append(
                        {
                            "latency_ms": (time.monotonic() - exec_start) * 1000,
                            "exit_code": -1,
                            "error": f"{type(exc).__name__}: {exc}",
                            "target": self._target,
                            "benchmark": self._spec.id,
                            "sandbox_id": sandbox_id,
                            "episode_idx": episode_idx,
                            "cold": cold,
                        }
                    )
            return records
        except Exception as exc:  # noqa: BLE001
            if not records:
                return [
                    {
                        "latency_ms": (time.monotonic() - create_start) * 1000,
                        "exit_code": -1,
                        "error": f"{type(exc).__name__}: {exc}",
                        "target": self._target,
                        "benchmark": self._spec.id,
                        "episode_idx": 0,
                        "cold": True,
                    }
                ]
            return records
        finally:
            if sandbox is not None:
                try:
                    self._client.delete(sandbox)
                except Exception:  # noqa: BLE001, S110
                    pass

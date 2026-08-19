"""RLP sandbox worker backend (rlp-sdk Daytona-compatible client)."""

from __future__ import annotations

import json
import threading
import time
from typing import Any

from dotenv import load_dotenv
from rlp import Daytona, Resources

from harness.benchmarks import AGENT, BenchmarkSpec
from harness.env_probe import failed_env, host_env, merge_env, parse_probe_stdout, probe_shell_command
from harness.paths import ROOT
from harness.regions import check_sandbox_arch, resolve_rlp_client_config
from harness.rlp_create import create_rlp_sandbox
from harness.rlp_snapshots import is_registry_image_ref, resolve_boot_image

# Native RLP disk snaps bake the app under /home/daytona/app (snapshot_common).
# Dockerfile.* images use WORKDIR /app — registry boots must match.
SNAPSHOT_APP_DIR = "/home/daytona/app"
REGISTRY_APP_DIR = "/app"
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
        mem = spec.memory_gib()
        # Match Docker mem; give a little disk headroom for parquet spills.
        self._resources = Resources(cpu=1, memory=mem, disk=max(2, mem))
        config = resolve_rlp_client_config(target, toolbox_url)
        self._client = Daytona(config)
        routing = getattr(config, "region_routing", None)
        print(
            f"rlp client: target={config.target!r} "
            f"api_url={config.api_url!r} toolbox_url={config.toolbox_url!r} "
            f"region_routing={routing!r} "
            f"benchmark={spec.id!r} episodes_per_sandbox={episodes_per_sandbox} "
            f"resources=cpu=1,memory={mem}GiB,disk={max(2, mem)}GiB"
        )

        # Probed once on the first worker sandbox (avoids a spare create on
        # capacity-constrained ARM64 regions).
        self._arch = "unspecified"
        self._arch_probed = skip_arch_probe or not target
        self._arch_lock = threading.Lock()

        self._boot_image = resolve_boot_image(self._client, self._snapshot)
        self._app_dir = (
            REGISTRY_APP_DIR
            if is_registry_image_ref(self._boot_image)
            else SNAPSHOT_APP_DIR
        )
        self._run_env = spec.run_env(self._app_dir)
        self._agent_cmd = spec.agent_command()
        print(
            f"rlp boot image: {self._snapshot!r} -> {self._boot_image!r} "
            f"(app_dir={self._app_dir})"
        )

    def probe_env(self) -> dict[str, Any]:
        host = host_env()
        sandbox = None
        try:
            sandbox = create_rlp_sandbox(
                self._client,
                image=self._boot_image,
                resources=self._resources,
                timeout=120,
                target=self._target,
            )
            if not self._arch_probed:
                with self._arch_lock:
                    if not self._arch_probed:
                        self._arch = check_sandbox_arch(sandbox, self._target)
                        self._arch_probed = True
            response = sandbox.process.exec(
                probe_shell_command(),
                timeout=60,
            )
            exit_code = int(response.exit_code or 0)
            stdout = (response.result or "").strip()
            if exit_code != 0:
                err = stdout or f"exit {exit_code}"
                print(f"warning: rlp env probe failed: {err[:200]}")
                return failed_env(host, probe="rlp", error=err[:500])
            remote = parse_probe_stdout(stdout)
            return merge_env(host, remote, probe="rlp")
        except Exception as exc:  # noqa: BLE001
            print(f"warning: rlp env probe failed: {exc}")
            return failed_env(host, probe="rlp", error=str(exc))
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

        Episode 0 is cold (create + first exec). Later episodes are warm
        (exec-only ``latency_ms``). ``duration_ms`` remains the chip metric.
        """
        episodes = self._episodes_per_sandbox if episodes is None else episodes
        if episodes < 1:
            raise ValueError("episodes must be >= 1")

        records: list[dict[str, Any]] = []
        sandbox = None
        create_start = time.monotonic()
        try:
            sandbox = create_rlp_sandbox(
                self._client,
                image=self._boot_image,
                resources=self._resources,
                timeout=120,
                target=self._target,
            )
            if not self._arch_probed:
                with self._arch_lock:
                    if not self._arch_probed:
                        self._arch = check_sandbox_arch(sandbox, self._target)
                        self._arch_probed = True
            sandbox_id = getattr(sandbox, "id", None)
            argv = " ".join(self._spec.agent_argv(n, seed))
            cmd = f"{self._agent_cmd} {argv}"

            for episode_idx in range(episodes):
                cold = episode_idx == 0
                exec_start = time.monotonic() if not cold else create_start
                try:
                    response = sandbox.process.exec(
                        cmd,
                        cwd=self._app_dir,
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
                        "arch": self._arch,
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
                            "arch": self._arch,
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
                        "arch": self._arch,
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

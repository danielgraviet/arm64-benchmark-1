#!/usr/bin/env python3
"""Parallel create fleet: spin up N sandboxes, optional ready probe, delete.

Modes:
  - Slim create-only (too fast for agent graphs): python:3.12-slim, no probe
  - Agent-shaped ready (graph-comparable): dtgraviet/vera-agent-benchmark:v3
    plus --probe 'echo ready' so each sandbox must exec successfully

Reports READY_WALL_S (create + probe wall for the whole fleet). Writes a JSONL
with meta, per-sandbox rows, and a summary so the run is auditable.

Vera (on-node /opt/bench or this repo):
  export PATH="$HOME/.local/bin:$PATH" UV_NO_SYNC=1 PYTHONUNBUFFERED=1
  ulimit -n 65536
  UV_NO_SYNC=1 uv run python scripts/rlp_light_create_fleet.py \\
    --target vera --count 1000 --workers 1000 \\
    --image dtgraviet/vera-agent-benchmark:v3 \\
    --probe 'echo ready' \\
    --output results/vera-jsonl/vera_create_ready_1000.jsonl

Zen5 (on-node /root/arm64-benchmark-1). Same ulimit and HTTP pool as Vera:
  export PATH="$HOME/.local/bin:$PATH" UV_NO_SYNC=1 PYTHONUNBUFFERED=1
  export RLP_HTTP_MAX_CONNECTIONS=4096
  ulimit -n 65536
  UV_NO_SYNC=1 uv run python scripts/rlp_light_create_fleet.py \\
    --target redswitches --count 1000 --workers 1000 \\
    --image dtgraviet/vera-agent-benchmark:v3 \\
    --probe 'echo ready'

Smoke first:
  ... --count 8 --workers 8
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import resource
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from rlp import CreateSandboxFromImageParams, Daytona, DaytonaConfig, Resources

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from harness import rlp_client_tuning  # noqa: E402
from harness.common import JsonlWriter  # noqa: E402
from harness.env_probe import parse_cpuinfo  # noqa: E402
from harness.runner_id import sdk_runner_id  # noqa: E402

AGENT_IMAGE = "dtgraviet/vera-agent-benchmark:v3"


def _env(*names: str) -> str:
    for name in names:
        val = (os.environ.get(name) or "").strip()
        if val:
            return val
    raise SystemExit(f"Missing env: tried {', '.join(names)}")


def _daytona_config(**kwargs) -> DaytonaConfig:
    """Drop kwargs the installed SDK does not accept (PyPI vs eng overlay)."""
    fields = getattr(DaytonaConfig, "__dataclass_fields__", {})
    return DaytonaConfig(**{k: v for k, v in kwargs.items() if k in fields})


def build_client(target: str) -> Daytona:
    if target == "vera":
        return Daytona(
            _daytona_config(
                api_url=_env("VERA_RLP_API_URL"),
                api_key=_env("VERA_RLP_API_KEY"),
                toolbox_url=_env("VERA_RLP_TOOLBOX_URL"),
                target=os.environ.get("VERA_RLP_TARGET", "vera").strip() or "vera",
                region_routing=False,
            )
        )
    if target == "redswitches":
        api = (
            os.environ.get("REDSWITCHES_RLP_API_URL")
            or os.environ.get("RLP_API_URL")
            or "http://127.0.0.1:8088"
        ).strip()
        key = _env("REDSWITCHES_RLP_API_KEY", "RLP_API_KEY", "RS_KEY")
        tb = (
            os.environ.get("REDSWITCHES_RLP_TOOLBOX_URL")
            or os.environ.get("RLP_TOOLBOX_URL")
            or "http://127.0.0.1:9000/toolbox"
        ).strip()
        return Daytona(
            _daytona_config(
                api_url=api,
                api_key=key,
                toolbox_url=tb,
                target="redswitches",
                region_routing=False,
            )
        )
    raise SystemExit(f"Unknown target {target!r}")


def build_params(
    *,
    target: str,
    image: str,
    cpu: float,
    memory: float,
    disk: float,
    idx: int,
) -> CreateSandboxFromImageParams:
    kwargs: dict = {
        "image": image,
        "name": f"light-create-{idx}",
        "resources": Resources(cpu=cpu, memory=memory, disk=disk),
    }
    if target == "vera":
        kwargs["cpu_arch"] = "arm64"
        kwargs["cpu_type"] = "vera"
    return CreateSandboxFromImageParams(**kwargs)


def _utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _git_sha() -> str | None:
    try:
        proc = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    sha = (proc.stdout or "").strip()
    return sha or None


def _lscpu_field(name: str) -> str | None:
    try:
        proc = subprocess.run(
            ["lscpu"], capture_output=True, text=True, check=False, timeout=5
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    prefix = name.lower() + ":"
    for line in (proc.stdout or "").splitlines():
        if line.lower().startswith(prefix):
            return line.split(":", 1)[1].strip() or None
    return None


def _host_cpu_model() -> str | None:
    model = _lscpu_field("Model name")
    if model:
        return model
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.is_file():
        try:
            return parse_cpuinfo(cpuinfo.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            return None
    return None


def _image_digest(image: str) -> str | None:
    try:
        proc = subprocess.run(
            [
                "docker",
                "image",
                "inspect",
                image,
                "--format",
                "{{index .RepoDigests 0}}",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    digest = (proc.stdout or "").strip()
    return digest or None


def _read_text(path: str) -> str | None:
    try:
        text = Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return text or None


def _socket_pin() -> dict[str, str | None]:
    """cgroup v2 pin applied by tickets/vera-pin-single-socket.sh."""
    return {
        "slice_cpus": _read_text("/sys/fs/cgroup/rlp.slice/cpuset.cpus"),
        "slice_mems": _read_text("/sys/fs/cgroup/rlp.slice/cpuset.mems"),
        "vms_cpus": _read_text("/sys/fs/cgroup/rlp.slice/vms/cpuset.cpus"),
        "vms_mems": _read_text("/sys/fs/cgroup/rlp.slice/vms/cpuset.mems"),
    }


def _ulimit_nofile() -> tuple[int | None, int | None]:
    try:
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    except (ValueError, OSError):
        return None, None
    inf = getattr(resource, "RLIM_INFINITY", -1)

    def _norm(value: int) -> int | None:
        if value == inf:
            return None
        return int(value)

    return _norm(int(soft)), _norm(int(hard))


# Vera create-ready wrapper used `ulimit -n 65536` and a 4096-wide HTTP pool.
# Record after raise so a 1024 login-shell default cannot masquerade as silicon.
VERA_CREATE_READY_NOFILE = 65536


def _raise_nofile_to_vera(want: int = VERA_CREATE_READY_NOFILE) -> None:
    """Pin soft NOFILE to Vera's create-ready cap (`ulimit -n 65536`).

    Raise a 1024 login default. Also lower a 1M systemd/login cap so the
    Zen5 client is the same FD budget Vera recorded, not a looser one.
    """
    try:
        _soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    except (ValueError, OSError):
        return
    inf = getattr(resource, "RLIM_INFINITY", -1)
    cap = want if hard == inf else min(want, int(hard))
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (cap, hard))
    except (ValueError, OSError):
        return


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    k = (len(ordered) - 1) * (pct / 100)
    f = int(k)
    c = min(f + 1, len(ordered) - 1)
    if f == c:
        return ordered[f]
    return ordered[f] + (ordered[c] - ordered[f]) * (k - f)


def _sandbox_id(sandbox: Any) -> str | None:
    sid = getattr(sandbox, "id", None)
    if sid:
        return str(sid)
    return None


def _default_output(target: str, count: int) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    folder = "vera-jsonl" if target == "vera" else "zen5-jsonl"
    return ROOT / "results" / folder / f"{target}_create_ready_{count}_{stamp}.jsonl"


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--target", choices=("vera", "redswitches"), required=True)
    p.add_argument("--count", type=int, default=2000)
    p.add_argument(
        "--image",
        default=AGENT_IMAGE,
        help=f"Hub image (default {AGENT_IMAGE}). Use python:3.12-slim for create-only smoke.",
    )
    p.add_argument("--cpu", type=float, default=0.025)
    p.add_argument("--memory", type=float, default=0.0625, help="GiB guarantee")
    p.add_argument("--disk", type=float, default=1.0)
    p.add_argument(
        "--workers",
        type=int,
        default=0,
        help="Parallel create workers (0 = equal to --count)",
    )
    p.add_argument("--timeout", type=int, default=180, help="Per-create timeout seconds")
    p.add_argument(
        "--probe",
        default="echo ready",
        help="Exec after create; must exit 0 and stdout contain 'ready'. Empty string skips.",
    )
    p.add_argument("--probe-timeout", type=int, default=60, help="Per-sandbox probe timeout")
    p.add_argument("--keep", action="store_true", help="Do not delete after timing")
    p.add_argument(
        "--output",
        type=str,
        default=None,
        help="JSONL path (default: results/<target>-jsonl/<target>_create_ready_<count>_<utc>.jsonl)",
    )
    args = p.parse_args()
    probe = (args.probe or "").strip()
    workers = args.count if args.workers <= 0 else args.workers
    output = Path(args.output) if args.output else _default_output(args.target, args.count)
    if not output.is_absolute():
        output = ROOT / output

    load_dotenv(ROOT / ".env")
    os.environ.setdefault("RLP_HTTP_MAX_CONNECTIONS", "4096")
    _raise_nofile_to_vera()
    rlp_client_tuning.apply()

    client = build_client(args.target)
    soft, hard = _ulimit_nofile()
    meta = {
        "type": "meta",
        "benchmark": "create-ready",
        "runner": "rlp",
        "target": args.target,
        "artifact": args.image,
        "artifact_digest": _image_digest(args.image),
        "sandboxes_requested": args.count,
        "workers": workers,
        "probe": probe or None,
        "cpu": args.cpu,
        "memory": args.memory,
        "disk": args.disk,
        "timeout_s": args.timeout,
        "probe_timeout_s": args.probe_timeout,
        "started_at_utc": _utcnow(),
        "client_host": socket.gethostname(),
        "ulimit_nofile_soft": soft,
        "ulimit_nofile_hard": hard,
        "rlp_client_tuning": rlp_client_tuning.settings(),
        "git_sha": _git_sha(),
        "argv": sys.argv,
        "socket_pin": _socket_pin(),
        "env": {
            "arch": platform.machine(),
            "cpu_model": _host_cpu_model(),
            "cpu_count": os.cpu_count(),
            "platform": platform.platform(),
            "host_arch": platform.machine(),
            "host_cpu": _host_cpu_model(),
            "sockets": _lscpu_field("Socket(s)"),
            "probe": "create-fleet-host",
        },
    }
    print(
        f"target={args.target} count={args.count} image={args.image!r} "
        f"cpu={args.cpu} mem={args.memory}GiB workers={workers} "
        f"probe={probe!r} output={output}",
        flush=True,
    )

    sandboxes: list = []
    errors: list[str] = []
    create_latencies: list[float] = []

    def one(i: int) -> dict[str, Any]:
        t_create = time.perf_counter()
        sb = client.create(
            build_params(
                target=args.target,
                image=args.image,
                cpu=args.cpu,
                memory=args.memory,
                disk=args.disk,
                idx=i,
            ),
            timeout=args.timeout,
        )
        create_s = time.perf_counter() - t_create
        probe_s = None
        if probe:
            t_probe = time.perf_counter()
            resp = sb.process.exec(probe, timeout=args.probe_timeout)
            probe_s = time.perf_counter() - t_probe
            code = int(resp.exit_code or 0)
            out = (resp.result or "").strip()
            if code != 0 or "ready" not in out.lower():
                try:
                    client.delete(sb)
                except Exception:  # noqa: BLE001
                    pass
                raise RuntimeError(f"probe failed exit={code} out={out!r}")
        return {
            "sandbox": sb,
            "record": {
                "type": "sandbox",
                "idx": i,
                "sandbox_id": _sandbox_id(sb),
                "runner_id": sdk_runner_id(sb),
                "status": "ok",
                "create_s": create_s,
                "probe_s": probe_s,
                "error": None,
            },
        }

    with JsonlWriter(output) as writer:
        writer.write(meta)
        t0 = time.perf_counter()
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futs = {pool.submit(one, i): i for i in range(args.count)}
            for fut in as_completed(futs):
                i = futs[fut]
                try:
                    result = fut.result()
                    sandboxes.append(result["sandbox"])
                    record = result["record"]
                    create_latencies.append(float(record["create_s"]))
                    writer.write(record)
                except Exception as e:  # noqa: BLE001
                    err = f"{type(e).__name__}:{e}"
                    errors.append(f"{i}:{err}")
                    writer.write(
                        {
                            "type": "sandbox",
                            "idx": i,
                            "sandbox_id": None,
                            "runner_id": None,
                            "status": "failed",
                            "create_s": None,
                            "probe_s": None,
                            "error": err,
                        }
                    )
        ready_s = time.perf_counter() - t0

        ok = len(sandboxes)
        create_wall_est = max(create_latencies) if create_latencies else 0.0
        rate = (ok / ready_s) if ready_s > 0 else 0.0
        print(
            f"READY_WALL_S={ready_s:.3f} CREATE_MAX_S={create_wall_est:.3f} "
            f"ok={ok} failed={len(errors)} rate={rate:.1f}/s",
            flush=True,
        )
        if errors:
            print(f"first_errors={errors[:5]}", flush=True)

        delete_s = None
        if not args.keep:
            t1 = time.perf_counter()
            with ThreadPoolExecutor(max_workers=workers) as pool:
                list(pool.map(lambda s: client.delete(s), sandboxes))
            delete_s = time.perf_counter() - t1
            print(f"DELETE_WALL_S={delete_s:.3f}", flush=True)

        writer.write(
            {
                "type": "summary",
                "sandboxes_requested": args.count,
                "sandboxes_created": ok,
                "ok": ok,
                "failed": len(errors),
                "ready_wall_s": ready_s,
                "create_max_s": create_wall_est,
                "create_p50_s": _percentile(create_latencies, 50),
                "create_p95_s": _percentile(create_latencies, 95),
                "delete_wall_s": delete_s,
                "ended_at_utc": _utcnow(),
                "status": "ok" if ok == args.count else "failed",
            }
        )

    print(f"wrote {output}", flush=True)
    if ok < args.count:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

"""Shared snapshot-build helpers so Daytona / RLP / E2B match Docker images."""

from __future__ import annotations

import base64
import tarfile
from pathlib import Path

from harness.benchmarks import AGENT, BenchmarkSpec

# Same base as Dockerfiles — keep in lockstep.
BASE_IMAGE = "ghcr.io/astral-sh/uv:python3.13-bookworm-slim"
APP_DIR = "/home/daytona/app"

ROOT = Path(__file__).resolve().parent.parent

# Back-compat aliases for older script imports.
SNAPSHOT_NAME = AGENT.artifact_name
INCLUDE_PATHS = AGENT.include_paths

SKIP_DIR_NAMES = {
    ".git",
    ".venv",
    "__pycache__",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".egg-info",
}


def should_skip(path: Path) -> bool:
    return any(part in SKIP_DIR_NAMES or part.endswith(".egg-info") for part in path.parts)


def build_archive(dest: Path, spec: BenchmarkSpec = AGENT) -> None:
    with tarfile.open(dest, "w:gz") as tar:
        for rel in spec.include_paths:
            src = ROOT / rel
            if not src.exists():
                raise FileNotFoundError(f"Missing required path: {src}")
            if src.is_file():
                tar.add(src, arcname=rel)
                continue
            for path in src.rglob("*"):
                if path.is_dir() or should_skip(path.relative_to(ROOT)):
                    continue
                tar.add(path, arcname=str(path.relative_to(ROOT)))


def exec_or_raise(sandbox, command: str, *, cwd: str | None = None, timeout: int = 600) -> str:
    print(f"$ {command}")
    response = sandbox.process.exec(command, cwd=cwd, timeout=timeout)
    output = (response.result or "").strip()
    if output:
        print(output)
    if response.exit_code not in (0, None):
        raise RuntimeError(f"Command failed ({response.exit_code}): {command}\n{output}")
    return output


def upload_bytes_via_exec(sandbox, content: bytes, remote_path: str) -> None:
    """Write bytes into the sandbox without toolbox fs.upload_file."""
    parent = str(Path(remote_path).parent)
    if parent not in ("", "."):
        exec_or_raise(sandbox, f"mkdir -p {parent}")

    b64 = base64.standard_b64encode(content).decode("ascii")
    staging = f"{remote_path}.b64"
    exec_or_raise(sandbox, f"rm -f {staging}")
    chunk_size = 60_000
    for i in range(0, len(b64), chunk_size):
        piece = b64[i : i + chunk_size]
        exec_or_raise(
            sandbox,
            "python -c \""
            f"from pathlib import Path; Path({staging!r}).open('a').write({piece!r})"
            "\"",
        )
    exec_or_raise(
        sandbox,
        "python -c \""
        "import base64, pathlib; "
        f"pathlib.Path({remote_path!r}).write_bytes("
        f"base64.b64decode(pathlib.Path({staging!r}).read_text())"
        "); "
        f"pathlib.Path({staging!r}).unlink()"
        "\"",
    )


def extract_and_uv_sync(sandbox, archive_path: str = "/tmp/app.tar.gz") -> None:
    """Mirror Dockerfile: unpack app, then `uv sync --frozen --no-dev`."""
    exec_or_raise(
        sandbox,
        f"mkdir -p {APP_DIR} && tar -xzf {archive_path} -C {APP_DIR}",
    )
    exec_or_raise(
        sandbox,
        f"cd {APP_DIR} && uv sync --frozen --no-dev",
        timeout=600,
    )


def ensure_uv(sandbox) -> None:
    """Install uv if missing (stock VM seeds do not ship the uv image)."""
    response = sandbox.process.exec("command -v uv", timeout=30)
    if response.exit_code in (0, None) and (response.result or "").strip():
        return
    print("uv not found on sandbox; installing via astral.sh …")
    # Slim seeds (e.g. python:*-slim on Graviton5) often lack curl.
    curl = sandbox.process.exec("command -v curl", timeout=30)
    if curl.exit_code not in (0, None) or not (curl.result or "").strip():
        print("curl missing; installing via apt …")
        apt_prefix = (
            "sudo DEBIAN_FRONTEND=noninteractive apt-get"
            if _sudo_available(sandbox)
            else "DEBIAN_FRONTEND=noninteractive apt-get"
        )
        exec_or_raise(sandbox, f"{apt_prefix} update", timeout=300)
        exec_or_raise(
            sandbox,
            f"{apt_prefix} install -y --no-install-recommends curl ca-certificates",
            timeout=300,
        )
    exec_or_raise(
        sandbox,
        "curl -LsSf https://astral.sh/uv/install.sh | sh",
        timeout=300,
    )
    # Official installer drops into ~/.local/bin; also symlink for non-login shells.
    exec_or_raise(
        sandbox,
        "export PATH=\"$HOME/.local/bin:$PATH\"; "
        "command -v uv && "
        "sudo ln -sf \"$(command -v uv)\" /usr/local/bin/uv 2>/dev/null || "
        "ln -sf \"$HOME/.local/bin/uv\" /usr/local/bin/uv 2>/dev/null || true",
        timeout=60,
    )
    # Fail hard if uv still missing (silent || true above can hide install issues).
    exec_or_raise(sandbox, "command -v uv && uv --version", timeout=30)


def install_system_packages(sandbox, spec: BenchmarkSpec) -> None:
    """Install apt packages declared on the benchmark (no-op if empty)."""
    if not spec.apt_packages:
        return
    pkgs = " ".join(spec.apt_packages)
    # Prefer sudo (stock VMs); fall back to plain apt (root container images).
    apt_prefix = (
        "sudo DEBIAN_FRONTEND=noninteractive apt-get"
        if _sudo_available(sandbox)
        else "DEBIAN_FRONTEND=noninteractive apt-get"
    )
    exec_or_raise(sandbox, f"{apt_prefix} update", timeout=300)
    exec_or_raise(
        sandbox,
        f"{apt_prefix} install -y --no-install-recommends {pkgs}",
        timeout=600,
    )


def _sudo_available(sandbox) -> bool:
    response = sandbox.process.exec("command -v sudo >/dev/null && sudo -n true", timeout=30)
    return response.exit_code in (0, None)


def smoke_agent(sandbox, spec: BenchmarkSpec = AGENT, *, app_dir: str = APP_DIR) -> None:
    """Run one workload pass with the same env the workers use."""
    env = spec.run_env(app_dir)
    env_prefix = " ".join(f"{k}={v}" for k, v in env.items())
    argv = " ".join(spec.agent_argv(1, 42))
    cmd = f"cd {app_dir} && {env_prefix} {spec.agent_command()} {argv}"
    print(f"Smoke-testing {spec.module} …")
    exec_or_raise(sandbox, cmd, timeout=600)


def start_import_keepalive(
    sandbox,
    spec: BenchmarkSpec = AGENT,
    *,
    app_dir: str = APP_DIR,
) -> None:
    """Import workload deps in a long-lived process so a hot memory snap stays warm.

    ``smoke_agent`` alone is not enough for hot snaps: the exec exits and drops
    the interpreter. This starts a background Python that imports ``numpy`` plus
    ``spec.module`` and sleeps, so ``include_memory=True`` captures that RSS.

    Daytona ``process.exec`` waits on the whole process tree, so a shell ``&``
    never returns — we spawn via ``subprocess.Popen(..., start_new_session=True)``.
    """
    env = spec.run_env(app_dir)
    warm_py = (
        "import importlib\n"
        "import sys\n"
        "import time\n"
        f"sys.path.insert(0, {app_dir!r})\n"
        "import numpy  # noqa: F401 — heavy BLAS touch for RL/analytics\n"
        f"importlib.import_module({spec.module!r})\n"
        f"importlib.import_module({spec.module.split('.')[0]!r})\n"
        "print('warm-ok', flush=True)\n"
        "time.sleep(10**9)\n"
    )
    upload_bytes_via_exec(sandbox, warm_py.encode("utf-8"), "/tmp/hot_warm_imports.py")

    env_items = ", ".join(f"{k!r}: {v!r}" for k, v in env.items())
    venv_python = f"{app_dir}/.venv/bin/python"
    launcher_py = (
        "import os, subprocess\n"
        "from pathlib import Path\n"
        f"app_dir = {app_dir!r}\n"
        f"python = {venv_python!r}\n"
        f"extra = {{{env_items}}}\n"
        "env = {**os.environ, **extra}\n"
        "log = open('/tmp/hot_warm_imports.log', 'w')\n"
        "proc = subprocess.Popen(\n"
        "    [python, '/tmp/hot_warm_imports.py'],\n"
        "    cwd=app_dir,\n"
        "    env=env,\n"
        "    stdout=log,\n"
        "    stderr=subprocess.STDOUT,\n"
        "    start_new_session=True,\n"
        ")\n"
        "Path('/tmp/hot_warm_imports.pid').write_text(str(proc.pid))\n"
        "print(proc.pid, flush=True)\n"
    )
    upload_bytes_via_exec(sandbox, launcher_py.encode("utf-8"), "/tmp/start_hot_warm.py")
    print(f"Starting import keep-alive for {spec.module!r} …")
    exec_or_raise(sandbox, f"{venv_python} /tmp/start_hot_warm.py", timeout=60)
    exec_or_raise(
        sandbox,
        "for i in $(seq 1 60); do "
        "grep -q warm-ok /tmp/hot_warm_imports.log 2>/dev/null && exit 0; "
        "sleep 1; "
        "done; "
        "echo 'keep-alive failed to report warm-ok:'; "
        "cat /tmp/hot_warm_imports.log 2>/dev/null || true; "
        "exit 1",
        timeout=120,
    )
    pid = exec_or_raise(sandbox, "cat /tmp/hot_warm_imports.pid", timeout=30)
    print(f"Import keep-alive ready (pid={pid.strip()})")


def prepare_hot_memory_snapshot(
    sandbox,
    spec: BenchmarkSpec = AGENT,
    *,
    app_dir: str = APP_DIR,
    skip_smoke: bool = False,
) -> None:
    """Smoke (optional) + import keep-alive before ``include_memory`` snapshot."""
    if not skip_smoke:
        smoke_agent(sandbox, spec, app_dir=app_dir)
    start_import_keepalive(sandbox, spec, app_dir=app_dir)


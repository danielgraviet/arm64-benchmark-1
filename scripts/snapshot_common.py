"""Shared snapshot-build helpers so Daytona / RLP match the Docker image."""

from __future__ import annotations

import base64
import tarfile
from pathlib import Path

# Same base as Dockerfile — keep these three in lockstep.
BASE_IMAGE = "ghcr.io/astral-sh/uv:python3.13-bookworm-slim"
SNAPSHOT_NAME = "vera-agent-benchmark"
APP_DIR = "/home/daytona/app"

ROOT = Path(__file__).resolve().parent.parent

INCLUDE_PATHS = (
    "pyproject.toml",
    "uv.lock",
    "workload",
)

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


def build_archive(dest: Path) -> None:
    with tarfile.open(dest, "w:gz") as tar:
        for rel in INCLUDE_PATHS:
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
    """Write bytes into the sandbox without toolbox fs.upload_file.

    RLP's toolbox ``/files/upload`` returns HTTP 400 on custom images; process.exec
    works. Base64 keeps the payload shell-safe.
    """
    parent = str(Path(remote_path).parent)
    if parent not in ("", "."):
        exec_or_raise(sandbox, f"mkdir -p {parent}")

    b64 = base64.standard_b64encode(content).decode("ascii")
    # Stay under typical ARG_MAX by chunking large archives into a staging file.
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


def smoke_agent(sandbox) -> None:
    """Run one agent pass with the same env the workers use."""
    cmd = (
        f"cd {APP_DIR} && "
        f"PATH={APP_DIR}/.venv/bin:$PATH "
        f"PYTHONPATH={APP_DIR}/workload/repos/sqlite-utils "
        f"PYTHONHASHSEED=0 "
        f"python -m workload.agent --n 1 --seed 42"
    )
    print("Smoke-testing workload.agent …")
    exec_or_raise(sandbox, cmd, timeout=600)

"""Build a reusable Daytona snapshot from a live sandbox.

Flow:
  1. Create a default Python sandbox
  2. Upload this repo's workload into it
  3. Install runtime deps + smoke-test workload.agent
  4. Stop the sandbox and snapshot the filesystem
  5. Delete the builder sandbox

Run once (or after workload changes):

    uv run scripts/build_daytona_snapshot.py
"""

from __future__ import annotations

import argparse
import tarfile
import tempfile
from pathlib import Path

from daytona import (
    CreateSandboxFromSnapshotParams,
    Daytona,
    DaytonaConfig,
    DaytonaError,
)
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT_NAME = "vera-agent-benchmark"
APP_DIR = "/home/daytona/app"

# Paths to pack into the sandbox (relative to repo root).
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

# Host-only deps (daytona, matplotlib, rlp-sdk) are not needed inside workers.
WORKLOAD_PIP_DEPS = [
    "click>=8.3.1",
    "click-default-group>=1.2.3",
    "pluggy",
    "python-dateutil",
    "sqlite-fts4",
    "tabulate",
    "pytest",
]


def _should_skip(path: Path) -> bool:
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
                if path.is_dir() or _should_skip(path.relative_to(ROOT)):
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


def delete_snapshot_if_exists(daytona: Daytona, name: str) -> None:
    try:
        existing = daytona.snapshot.get(name)
    except DaytonaError:
        return
    print(f"Deleting existing snapshot {name!r} …")
    daytona.snapshot.delete(existing)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build vera-agent-benchmark by snapshotting a configured sandbox"
    )
    parser.add_argument("--name", default=SNAPSHOT_NAME, help="Snapshot name")
    parser.add_argument(
        "--skip-smoke",
        action="store_true",
        help="Skip running workload.agent --n 1 before snapshotting",
    )
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    daytona = Daytona(DaytonaConfig(connection_pool_maxsize=None))

    delete_snapshot_if_exists(daytona, args.name)

    sandbox = None
    try:
        print("Creating builder sandbox …")
        # Do not use ephemeral=True: cold snapshots require stop(), and
        # ephemeral sandboxes are deleted immediately on stop.
        sandbox = daytona.create(
            CreateSandboxFromSnapshotParams(
                language="python",
                auto_delete_interval=-1,
            ),
            timeout=120,
        )
        print(f"Sandbox ready: {sandbox.id}")

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "app.tar.gz"
            print("Packing workload …")
            build_archive(archive)
            print(f"Uploading archive ({archive.stat().st_size} bytes) …")
            sandbox.fs.upload_file(str(archive), "/tmp/app.tar.gz")

        exec_or_raise(sandbox, f"mkdir -p {APP_DIR} && tar -xzf /tmp/app.tar.gz -C {APP_DIR}")
        exec_or_raise(
            sandbox,
            "python -m pip install --upgrade pip && python -m pip install "
            + " ".join(f"'{dep}'" for dep in WORKLOAD_PIP_DEPS),
            timeout=600,
        )

        smoke_cmd = (
            f"PYTHONPATH={APP_DIR}/workload/repos/sqlite-utils "
            f"PYTHONHASHSEED=0 "
            f"python -m workload.agent --n 1 --seed 42"
        )
        if not args.skip_smoke:
            print("Smoke-testing workload.agent …")
            exec_or_raise(sandbox, smoke_cmd, cwd=APP_DIR, timeout=600)

        print("Stopping sandbox for cold snapshot …")
        sandbox.stop(timeout=120)

        print(f"Creating snapshot {args.name!r} …")
        sandbox.create_snapshot(args.name, timeout=600)
        print(f"Ready: {args.name}")
    finally:
        if sandbox is not None:
            try:
                print(f"Deleting builder sandbox {sandbox.id} …")
                daytona.delete(sandbox)
            except Exception as exc:  # noqa: BLE001
                print(f"Warning: failed to delete builder sandbox: {exc}")


if __name__ == "__main__":
    main()

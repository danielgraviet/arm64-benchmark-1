"""Build a reusable Daytona snapshot from a live sandbox.

Matches Docker/RLP: same base image + `uv sync --frozen --no-dev`.

Flow:
  1. Create a sandbox from the Docker base image
  2. Upload workload + uv sync
  3. Smoke-test workload.agent
  4. Stop + cold-snapshot the filesystem
  5. Delete the builder sandbox

    uv run scripts/build_daytona_snapshot.py
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from daytona import (
    CreateSandboxFromImageParams,
    Daytona,
    DaytonaConfig,
    DaytonaError,
    Resources,
)
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import (  # noqa: E402
    APP_DIR,
    BASE_IMAGE,
    ROOT,
    SNAPSHOT_NAME,
    build_archive,
    extract_and_uv_sync,
    smoke_agent,
)


def delete_snapshot_if_exists(daytona: Daytona, name: str) -> None:
    try:
        existing = daytona.snapshot.get(name)
    except DaytonaError:
        return
    print(f"Deleting existing snapshot {name!r} …")
    daytona.snapshot.delete(existing)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build vera-agent-benchmark Daytona snapshot (aligned with Docker)"
    )
    parser.add_argument("--name", default=SNAPSHOT_NAME, help="Snapshot name")
    parser.add_argument(
        "--base-image",
        default=BASE_IMAGE,
        help=f"Base image (default: {BASE_IMAGE})",
    )
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
        print(f"Creating Daytona builder sandbox from {args.base_image!r} …")
        # Do not use ephemeral=True: cold snapshots require stop(), and
        # ephemeral sandboxes are deleted immediately on stop.
        sandbox = daytona.create(
            CreateSandboxFromImageParams(
                image=args.base_image,
                language="python",
                auto_delete_interval=-1,
                resources=Resources(cpu=1, memory=1),
            ),
            timeout=300,
        )
        print(f"Sandbox ready: {sandbox.id}")

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "app.tar.gz"
            print("Packing workload …")
            build_archive(archive)
            print(f"Uploading archive ({archive.stat().st_size} bytes) …")
            sandbox.fs.upload_file(str(archive), "/tmp/app.tar.gz")

        extract_and_uv_sync(sandbox)
        if not args.skip_smoke:
            smoke_agent(sandbox)

        print("Stopping sandbox for cold snapshot …")
        sandbox.stop(timeout=120)

        print(f"Creating snapshot {args.name!r} …")
        sandbox.create_snapshot(args.name, timeout=600)
        print(f"Ready: {args.name} (base={args.base_image})")
    finally:
        if sandbox is not None:
            try:
                print(f"Deleting builder sandbox {sandbox.id} …")
                daytona.delete(sandbox)
            except Exception as exc:  # noqa: BLE001
                print(f"Warning: failed to delete builder sandbox: {exc}")


if __name__ == "__main__":
    main()

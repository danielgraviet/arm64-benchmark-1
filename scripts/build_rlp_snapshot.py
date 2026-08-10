"""Build vera-agent-benchmark on RLP (rl-platform).

Matches Docker/Daytona: same base image + `uv sync --frozen --no-dev`.

Creates a *native* disk snapshot (``POST /vms/:id/snapshots``). The RLP web UI
and the harness boot from that snapshot's ``manifest_name`` (``snap-<uuid>``).

Requires in `.env`:
  RLP_API_KEY, RLP_API_URL, RLP_TOOLBOX_URL

    uv run scripts/build_rlp_snapshot.py
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from dotenv import load_dotenv
from rlp import (
    CreateSandboxFromImageParams,
    Daytona,
    DaytonaConfig,
    Resources,
)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.rlp_snapshots import (  # noqa: E402
    delete_native_snapshot_if_exists,
    wait_for_native_snapshot,
)
from harness.paths import ROOT  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import (  # noqa: E402
    BASE_IMAGE,
    SNAPSHOT_NAME,
    build_archive,
    extract_and_uv_sync,
    smoke_agent,
    upload_bytes_via_exec,
)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build vera-agent-benchmark native snapshot on RLP"
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
    client = Daytona(DaytonaConfig())

    delete_native_snapshot_if_exists(client, args.name)

    sandbox = None
    try:
        print(f"Creating RLP builder sandbox from {args.base_image!r} …")
        sandbox = client.create(
            CreateSandboxFromImageParams(
                image=args.base_image,
                resources=Resources(cpu=1, memory=1),
            ),
            timeout=300,
        )
        print(f"Sandbox ready: {sandbox.id}")

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "app.tar.gz"
            print("Packing workload …")
            build_archive(archive)
            content = archive.read_bytes()
            # RLP toolbox fs.upload_file returns HTTP 400 on this image; use exec.
            print(f"Uploading archive via exec ({len(content)} bytes) …")
            upload_bytes_via_exec(sandbox, content, "/tmp/app.tar.gz")

        extract_and_uv_sync(sandbox)
        if not args.skip_smoke:
            smoke_agent(sandbox)

        # Native disk snapshot — sandbox must stay running.
        print(f"Creating native RLP snapshot {args.name!r} …")
        result = sandbox.create_snapshot(args.name, kind="disk")
        print(f"snapshot job started: {result}")
        snap = wait_for_native_snapshot(
            client,
            args.name,
            snapshot_id=result.get("snapshot_id"),
        )
        print(
            f"Ready on RLP: name={snap.get('name')!r} "
            f"manifest={snap.get('manifest_name')!r} "
            f"status={snap.get('status')!r}"
        )
        print("Harness will boot with: --snapshot", args.name)
    finally:
        if sandbox is not None:
            try:
                print(f"Deleting builder sandbox {sandbox.id} …")
                client.delete(sandbox)
            except Exception as exc:  # noqa: BLE001
                print(f"Warning: failed to delete builder sandbox: {exc}")


if __name__ == "__main__":
    main()

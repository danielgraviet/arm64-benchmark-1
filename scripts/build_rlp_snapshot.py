"""Build vera-agent-benchmark on RLP (rl-platform).

Matches Docker/Daytona: same base image + `uv sync --frozen --no-dev`.

Creates a *native* disk snapshot (``POST /vms/:id/snapshots``). The RLP web UI
and the harness boot from that snapshot's ``manifest_name`` (``snap-<uuid>``).

Requires in `.env`:
  RLP_API_KEY, RLP_API_URL

For ARM64, pass ``--target arm64-test-1`` (toolbox URL is mapped automatically).
Do not rely on a sticky x86 ``RLP_TOOLBOX_URL`` when building for ARM64.

    uv run scripts/build_rlp_snapshot.py
    uv run scripts/build_rlp_snapshot.py --target arm64-test-1
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from dotenv import load_dotenv
from rlp import CreateSandboxFromImageParams, Daytona, Resources

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.paths import ROOT
from harness.regions import check_sandbox_arch, resolve_rlp_client_config
from harness.rlp_snapshots import (
    delete_native_snapshot_if_exists,
    wait_for_native_snapshot,
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import (
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
        "--target",
        type=str,
        default=None,
        help="RLP region/target (e.g. arm64-test-1)",
    )
    parser.add_argument(
        "--toolbox-url",
        type=str,
        default=None,
        help="Override RLP toolbox proxy URL for this target",
    )
    parser.add_argument(
        "--skip-smoke",
        action="store_true",
        help="Skip running workload.agent --n 1 before snapshotting",
    )
    parser.add_argument(
        "--skip-arch-probe",
        action="store_true",
        help="Skip platform.machine() probe for ARM64 targets",
    )
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")
    config = resolve_rlp_client_config(args.target, args.toolbox_url)
    client = Daytona(config)
    print(f"rlp client: target={config.target!r} toolbox_url={config.toolbox_url!r}")

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

        # Probe on the builder itself — no spare create (ARM64 capacity is tight).
        if args.target and not args.skip_arch_probe:
            check_sandbox_arch(sandbox, args.target)

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
            f"status={snap.get('status')!r} "
            f"target={args.target!r}"
        )
        if args.target:
            print(
                "Harness: uv run main.py --runner rlp "
                f"--target {args.target} --snapshot {args.name}"
            )
        else:
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

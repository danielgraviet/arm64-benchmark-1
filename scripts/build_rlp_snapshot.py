"""Build a native RLP disk snapshot for a Vera benchmark.

    uv run scripts/build_rlp_snapshot.py --benchmark agent
    uv run scripts/build_rlp_snapshot.py --benchmark analytics
    uv run scripts/build_rlp_snapshot.py --benchmark analytics --target arm64-test-1
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from dotenv import load_dotenv
from rlp import Daytona, Resources

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.benchmarks import SNAPSHOT_BENCHMARK_IDS, get_benchmark
from harness.paths import ROOT
from harness.regions import check_sandbox_arch, resolve_rlp_client_config
from harness.rlp_create import create_rlp_sandbox
from harness.rlp_snapshots import (
    delete_native_snapshot_if_exists,
    wait_for_native_snapshot,
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import (
    BASE_IMAGE,
    build_archive,
    extract_and_uv_sync,
    install_system_packages,
    smoke_agent,
    upload_bytes_via_exec,
)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build native RLP snapshot for a Vera benchmark"
    )
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=SNAPSHOT_BENCHMARK_IDS,
        help="Which benchmark package to bake into the snapshot",
    )
    parser.add_argument(
        "--name",
        default=None,
        help="Snapshot name (default: per-benchmark artifact name)",
    )
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
        help="Skip running the workload --n 1 before snapshotting",
    )
    parser.add_argument(
        "--skip-arch-probe",
        action="store_true",
        help="Skip platform.machine() probe for ARM64 targets",
    )
    args = parser.parse_args()
    spec = get_benchmark(args.benchmark)
    # With --target, default to a distinct name so we never delete/overwrite
    # default-region snaps like vera-analytics-benchmark / vera-agent-benchmark.
    name = args.name or spec.artifact_for_target(args.target)

    load_dotenv(ROOT / ".env")
    config = resolve_rlp_client_config(args.target, args.toolbox_url)
    client = Daytona(config)
    print(
        f"rlp client: target={config.target!r} toolbox_url={config.toolbox_url!r} "
        f"benchmark={spec.id!r}"
    )
    print(f"snapshot name: {name!r}")
    if args.target and name == spec.artifact_name:
        print(
            "WARNING: --name matches the default-region artifact; "
            "rebuild may delete that snapshot if /snapshots is shared."
        )
    elif args.target:
        print(
            f"(default-region {spec.artifact_name!r} is left alone; "
            "only this targeted name is replaced if it already exists)"
        )

    delete_native_snapshot_if_exists(client, name)

    sandbox = None
    try:
        print(f"Creating RLP builder sandbox from {args.base_image!r} …")
        sandbox = create_rlp_sandbox(
            client,
            image=args.base_image,
            resources=Resources(cpu=1, memory=1),
            timeout=300,
            target=args.target,
        )
        print(f"Sandbox ready: {sandbox.id}")

        if args.target and not args.skip_arch_probe:
            check_sandbox_arch(sandbox, args.target)

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "app.tar.gz"
            print(f"Packing {spec.include_paths} …")
            build_archive(archive, spec)
            content = archive.read_bytes()
            print(f"Uploading archive via exec ({len(content)} bytes) …")
            upload_bytes_via_exec(sandbox, content, "/tmp/app.tar.gz")

        extract_and_uv_sync(sandbox)
        install_system_packages(sandbox, spec)
        if not args.skip_smoke:
            smoke_agent(sandbox, spec)

        print(f"Creating native RLP snapshot {name!r} …")
        result = sandbox.create_snapshot(name, kind="disk")
        print(f"snapshot job started: {result}")
        snap = wait_for_native_snapshot(
            client,
            name,
            snapshot_id=result.get("snapshot_id"),
        )
        print(
            f"Ready on RLP: name={snap.get('name')!r} "
            f"manifest={snap.get('manifest_name')!r} "
            f"status={snap.get('status')!r} "
            f"target={args.target!r} benchmark={spec.id!r}"
        )
        cmd = f"uv run main.py --benchmark {spec.id} --runner rlp --snapshot {name}"
        if args.target:
            cmd += f" --target {args.target}"
        print("Harness:", cmd)
    finally:
        if sandbox is not None:
            try:
                print(f"Deleting builder sandbox {sandbox.id} …")
                client.delete(sandbox)
            except Exception as exc:  # noqa: BLE001
                print(f"Warning: failed to delete builder sandbox: {exc}")


if __name__ == "__main__":
    main()

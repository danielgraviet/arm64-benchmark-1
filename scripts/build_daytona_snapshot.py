"""Build a reusable Daytona snapshot from a live sandbox.

Matches Docker/RLP: same base image + `uv sync --frozen --no-dev`.

    uv run scripts/build_daytona_snapshot.py --benchmark agent
    uv run scripts/build_daytona_snapshot.py --benchmark analytics
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

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.benchmarks import SNAPSHOT_BENCHMARK_IDS, get_benchmark

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import (  # noqa: E402
    BASE_IMAGE,
    ROOT,
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
        description="Build Daytona snapshot for a Vera benchmark"
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
        "--skip-smoke",
        action="store_true",
        help="Skip running the workload --n 1 before snapshotting",
    )
    args = parser.parse_args()
    spec = get_benchmark(args.benchmark)
    name = args.name or spec.artifact_name

    load_dotenv(ROOT / ".env")
    daytona = Daytona(DaytonaConfig(connection_pool_maxsize=None))

    delete_snapshot_if_exists(daytona, name)

    sandbox = None
    try:
        print(
            f"Creating Daytona builder sandbox from {args.base_image!r} "
            f"(benchmark={spec.id}) …"
        )
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
            print(f"Packing {spec.include_paths} …")
            build_archive(archive, spec)
            print(f"Uploading archive ({archive.stat().st_size} bytes) …")
            sandbox.fs.upload_file(str(archive), "/tmp/app.tar.gz")

        extract_and_uv_sync(sandbox)
        if not args.skip_smoke:
            smoke_agent(sandbox, spec)

        print("Stopping sandbox for cold snapshot …")
        sandbox.stop(timeout=120)

        print(f"Creating snapshot {name!r} …")
        sandbox.create_snapshot(name, timeout=600)
        print(f"Ready: {name} (benchmark={spec.id}, base={args.base_image})")
        print(f"Harness: uv run main.py --benchmark {spec.id} --runner daytona")
    finally:
        if sandbox is not None:
            try:
                print(f"Deleting builder sandbox {sandbox.id} …")
                daytona.delete(sandbox)
            except Exception as exc:  # noqa: BLE001
                print(f"Warning: failed to delete builder sandbox: {exc}")


if __name__ == "__main__":
    main()

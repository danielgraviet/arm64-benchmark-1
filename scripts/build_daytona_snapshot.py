"""Build a reusable Daytona snapshot from a live sandbox.

Container path (default): same base image + ``uv sync --frozen --no-dev``.

Linux VM path (``--class linux-vm``): boot stock ``daytona-vm-medium`` in
``us-west-3``, bake workload, then write cold and/or hot snapshots:

- cold: stop VM → disk snapshot ``vera-*-benchmark-vm`` (default create_snapshot)
- hot: keep running → memory snapshot ``vera-*-benchmark-vm-hot`` (includeMemory)

Target ``us-east-1-arm`` (Graviton5) only has linux-vm runners — no container
class and no stock ``daytona-vm-*`` seeds. The builder registers a public
pinned image as a linux-vm seed snap, then bakes the workload on top.

    uv run scripts/build_daytona_snapshot.py --benchmark media --class linux-vm
    uv run scripts/build_daytona_snapshot.py --benchmark media --class linux-vm --vm-snap hot
    uv run scripts/build_daytona_snapshot.py --benchmark evals --class linux-vm --target us-east-1-arm --vm-snap cold
"""

from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

from daytona import (
    CreateSandboxFromImageParams,
    CreateSandboxFromSnapshotParams,
    CreateSnapshotParams,
    Daytona,
    DaytonaConfig,
    DaytonaError,
    Resources,
)
from daytona_api_client.models.sandbox_class import SandboxClass
from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.benchmarks import SNAPSHOT_BENCHMARK_IDS, get_benchmark
from harness.daytona_snapshots import create_named_snapshot
from harness.regions import DAYTONA_GRAVITON5_TARGET
from harness.runners.daytona import DEFAULT_VM_TARGET, default_daytona_snapshot

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot_common import (  # noqa: E402
    BASE_IMAGE,
    ROOT,
    build_archive,
    ensure_uv,
    extract_and_uv_sync,
    install_system_packages,
    smoke_agent,
)

# Stock Linux VM seed (2 GiB) — matches analytics/media/disk docker_memory.
VM_SEED_SNAPSHOT = "daytona-vm-medium"
# Public pinned image for targets without stock VM seeds (no :latest — API rejects it).
GRAVITON5_VM_SEED_IMAGE = "python:3.13-slim-bookworm"


def delete_snapshot_if_exists(daytona: Daytona, name: str) -> None:
    try:
        existing = daytona.snapshot.get(name)
    except DaytonaError:
        return
    print(f"Deleting existing snapshot {name!r} …")
    daytona.snapshot.delete(existing)


def ensure_linux_vm_seed(
    daytona: Daytona,
    *,
    seed_name: str,
    image: str,
    memory_gib: int,
) -> str:
    """Ensure a linux-vm snapshot exists on the current client target.

    Used when stock ``daytona-vm-*`` seeds are not available (e.g. Graviton5).
    """
    try:
        existing = daytona.snapshot.get(seed_name)
        print(
            f"Reusing linux-vm seed {seed_name!r} "
            f"(regions={getattr(existing, 'region_ids', None)})"
        )
        return seed_name
    except DaytonaError:
        pass
    print(
        f"Registering linux-vm seed {seed_name!r} from image {image!r} "
        f"(memory={memory_gib}GiB) …"
    )
    daytona.snapshot.create(
        CreateSnapshotParams(
            name=seed_name,
            image=image,
            resources=Resources(
                cpu=1,
                memory=memory_gib,
                disk=max(3, memory_gib),
            ),
            sandbox_class=SandboxClass.LINUX_VM,
        ),
        on_logs=lambda chunk: print(chunk, end=""),
        timeout=600,
    )
    print()
    return seed_name


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
        help="Override cold snapshot name (default: artifact or artifact-vm)",
    )
    parser.add_argument(
        "--class",
        dest="sandbox_class",
        default="container",
        choices=("container", "linux-vm"),
        help="container (default) or linux-vm for Daytona VM sandboxes",
    )
    parser.add_argument(
        "--vm-snap",
        default="both",
        choices=("cold", "hot", "both"),
        help="For linux-vm: write cold disk snap, hot memory snap, or both (default)",
    )
    parser.add_argument(
        "--target",
        default=None,
        help=(
            f"Daytona region/target (linux-vm defaults to {DEFAULT_VM_TARGET}; "
            "stock VM seeds are not in default us)"
        ),
    )
    parser.add_argument(
        "--base-image",
        default=BASE_IMAGE,
        help=f"Container base image (default: {BASE_IMAGE}; ignored for linux-vm)",
    )
    parser.add_argument(
        "--vm-seed",
        default=VM_SEED_SNAPSHOT,
        help=f"Stock VM snapshot to provision from (default: {VM_SEED_SNAPSHOT})",
    )
    parser.add_argument(
        "--skip-smoke",
        action="store_true",
        help="Skip running the workload --n 1 before snapshotting",
    )
    args = parser.parse_args()
    spec = get_benchmark(args.benchmark)
    # Graviton5 target has linux-vm runners only (no container class).
    if args.target == DAYTONA_GRAVITON5_TARGET and args.sandbox_class == "container":
        print(
            f"target {DAYTONA_GRAVITON5_TARGET!r} has no container runners; "
            "using --class linux-vm"
        )
        args.sandbox_class = "linux-vm"
    kind = "vm" if args.sandbox_class == "linux-vm" else "container"
    target = args.target or (DEFAULT_VM_TARGET if kind == "vm" else None)
    if args.name:
        cold_name = args.name
    elif target:
        # Keep a distinct snap name per target so default-region snaps stay intact.
        cold_name = spec.artifact_for_target(target)
    else:
        cold_name = default_daytona_snapshot(spec, kind, vm_boot="cold")
    hot_name = (
        f"{spec.artifact_for_target(target)}-hot"
        if target
        else default_daytona_snapshot(spec, "vm", vm_boot="hot")
    )

    load_dotenv(ROOT / ".env")
    config = DaytonaConfig(connection_pool_maxsize=None)
    if target:
        config = DaytonaConfig(connection_pool_maxsize=None, target=target)
    daytona = Daytona(config)
    print(f"daytona builder: target={target!r} class={args.sandbox_class}")

    want_cold = kind == "container" or args.vm_snap in ("cold", "both")
    want_hot = kind == "vm" and args.vm_snap in ("hot", "both")
    if want_cold:
        delete_snapshot_if_exists(daytona, cold_name)
    if want_hot:
        delete_snapshot_if_exists(daytona, hot_name)

    sandbox = None
    try:
        if kind == "vm":
            vm_seed = args.vm_seed
            if target == DAYTONA_GRAVITON5_TARGET and vm_seed == VM_SEED_SNAPSHOT:
                vm_seed = ensure_linux_vm_seed(
                    daytona,
                    seed_name=f"vera-linux-vm-seed-{target}",
                    image=GRAVITON5_VM_SEED_IMAGE,
                    memory_gib=spec.memory_gib(),
                )
            print(
                f"Creating Daytona Linux VM builder from seed {vm_seed!r} "
                f"(benchmark={spec.id}, target={target!r}) …"
            )
            sandbox = daytona.create(
                CreateSandboxFromSnapshotParams(
                    snapshot=vm_seed,
                    language="python",
                    auto_delete_interval=-1,
                ),
                timeout=300,
            )
        else:
            print(
                f"Creating Daytona builder sandbox from {args.base_image!r} "
                f"(benchmark={spec.id}, memory={spec.memory_gib()}GiB) …"
            )
            sandbox = daytona.create(
                CreateSandboxFromImageParams(
                    image=args.base_image,
                    language="python",
                    auto_delete_interval=-1,
                    resources=Resources(
                        cpu=1,
                        memory=spec.memory_gib(),
                        disk=max(3, spec.memory_gib()),
                    ),
                ),
                timeout=300,
            )
        print(f"Sandbox ready: {sandbox.id}")

        if kind == "vm":
            ensure_uv(sandbox)

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "app.tar.gz"
            print(f"Packing {spec.include_paths} …")
            build_archive(archive, spec)
            print(f"Uploading archive ({archive.stat().st_size} bytes) …")
            sandbox.fs.upload_file(str(archive), "/tmp/app.tar.gz")

        extract_and_uv_sync(sandbox)
        install_system_packages(sandbox, spec)
        if not args.skip_smoke:
            smoke_agent(sandbox, spec)

        if want_hot:
            # Hot memory snap requires STARTED VM (eng: RLP-ish warm boot).
            print(f"Creating HOT memory snapshot {hot_name!r} (sandbox started) …")
            create_named_snapshot(
                sandbox, hot_name, include_memory=True, timeout=600
            )
            print(f"Ready hot: {hot_name}")
            print(
                f"Harness: uv run main.py --benchmark {spec.id} "
                f"--runner daytona-vm-hot --target {target}"
            )

        if want_cold:
            print("Stopping sandbox for COLD disk snapshot …")
            sandbox.stop(timeout=120)
            print(f"Creating COLD disk snapshot {cold_name!r} …")
            create_named_snapshot(
                sandbox, cold_name, include_memory=False, timeout=600
            )
            print(
                f"Ready cold: {cold_name} (benchmark={spec.id}, "
                f"class={args.sandbox_class}, seed={vm_seed if kind == 'vm' else args.base_image})"
            )
            runner = "daytona-vm" if kind == "vm" else "daytona"
            cmd = f"uv run main.py --benchmark {spec.id} --runner {runner}"
            if target:
                cmd += f" --target {target}"
            print(f"Harness: {cmd}")
    finally:
        if sandbox is not None:
            try:
                print(f"Deleting builder sandbox {sandbox.id} …")
                daytona.delete(sandbox)
            except Exception as exc:  # noqa: BLE001
                print(f"Warning: failed to delete builder sandbox: {exc}")


if __name__ == "__main__":
    main()

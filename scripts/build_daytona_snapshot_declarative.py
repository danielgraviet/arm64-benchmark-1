"""Reproduce Daytona's declarative Dockerfile → snapshot build path.

This is the approach that failed with an S3/DNS timeout while fetching the
uploaded build-context tar. Kept as a separate script so we can reproduce and
file an eng report without touching the working sandbox→snapshot builder.

    uv run scripts/build_daytona_snapshot_declarative.py
"""

from __future__ import annotations

import argparse
import traceback
from pathlib import Path

from daytona import (
    CreateSnapshotParams,
    Daytona,
    DaytonaConfig,
    Image,
    Resources,
)
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT_NAME = "vera-agent-benchmark-declarative"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Reproduce declarative Image.from_dockerfile snapshot create"
    )
    parser.add_argument(
        "--name",
        default=SNAPSHOT_NAME,
        help=f"Snapshot name (default: {SNAPSHOT_NAME})",
    )
    parser.add_argument(
        "--dockerfile",
        type=Path,
        default=ROOT / "Dockerfile",
        help="Path to Dockerfile",
    )
    args = parser.parse_args()

    load_dotenv(ROOT / ".env")

    dockerfile = args.dockerfile.resolve()
    if not dockerfile.is_file():
        raise FileNotFoundError(f"Dockerfile not found: {dockerfile}")

    # Same shape as the failing call: build context upload + remote image build.
    image = Image.from_dockerfile(dockerfile).entrypoint(["sleep", "infinity"])

    daytona = Daytona(DaytonaConfig(connection_pool_maxsize=None))
    print(f"Creating snapshot {args.name!r} from {dockerfile} …")
    print("(declarative path: Image.from_dockerfile → snapshot.create)")
    try:
        snapshot = daytona.snapshot.create(
            CreateSnapshotParams(
                name=args.name,
                image=image,
                resources=Resources(cpu=1, memory=1),
                entrypoint=["sleep", "infinity"],
            ),
            on_logs=lambda chunk: print(chunk, end=""),
        )
    except Exception as exc:
        print()
        print("=== REPRO FAILURE ===")
        print(f"exception_type: {type(exc).__name__}")
        print(f"exception: {exc}")
        print("--- traceback ---")
        traceback.print_exc()
        raise SystemExit(1) from exc

    print()
    print(f"Ready: {snapshot.name} (state={snapshot.state})")
    print("(declarative path succeeded this time — no repro)")


if __name__ == "__main__":
    main()

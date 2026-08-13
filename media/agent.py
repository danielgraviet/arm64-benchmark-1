"""Media benchmark entrypoint (Docker / sandbox workers)."""

from __future__ import annotations

import argparse
import hashlib
import json
import time

from media import pipeline


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vera media / FFmpeg bandwidth probe")
    parser.add_argument(
        "--n",
        type=int,
        default=1,
        help="Scale factor (frames = n * 90; Chart C uses ~40–80)",
    )
    parser.add_argument(
        "--task",
        type=str,
        default="media-transcode-v1",
        help="Workload scenario name",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Fixed seed for deterministic synthetic frames",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="json",
        choices=["json"],
        help="Output format",
    )
    return parser.parse_args()


def compute_checksum(*parts: object) -> str:
    hasher = hashlib.sha256()
    for part in parts:
        hasher.update(json.dumps(part, sort_keys=True).encode("utf-8"))
    return hasher.hexdigest()


def main() -> None:
    args = parse_args()
    start = time.perf_counter()
    result = pipeline.run(n=args.n, seed=args.seed)
    duration_ms = int((time.perf_counter() - start) * 1000)
    checksum = compute_checksum(result)
    print(
        json.dumps(
            {
                "task": args.task,
                "iterations": args.n,
                "duration_ms": duration_ms,
                "checksum": checksum,
            }
        )
    )


if __name__ == "__main__":
    main()

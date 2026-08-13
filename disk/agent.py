"""Disk benchmark entrypoint (Docker / sandbox workers)."""

from __future__ import annotations

import argparse
import hashlib
import json
import time

from disk import pipeline


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Vera sandbox-disk I/O probe (seq + small files)"
    )
    parser.add_argument(
        "--n",
        type=int,
        default=1,
        help="Scale factor (sequential MiB + n*64 small files; eng ladder ~128)",
    )
    parser.add_argument(
        "--task",
        type=str,
        default="sandbox-disk-v1",
        help="Workload scenario name",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="Fixed seed for deterministic file contents",
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
                "bytes_written": result["bytes_written"],
                "bytes_read": result["bytes_read"],
                "files_touched": result["files_touched"],
            }
        )
    )


if __name__ == "__main__":
    main()

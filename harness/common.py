"""Shared concurrency harness helpers."""

from __future__ import annotations

import json
import time
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Self, TextIO

RunOne = Callable[[int, int], dict[str, Any]]


class JsonlWriter:
    """Append-only JSON Lines writer that flushes after every record."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._fp: TextIO | None = None

    def __enter__(self) -> Self:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._fp = self._path.open("w", encoding="utf-8")
        return self

    def __exit__(self, *exc: object) -> None:
        if self._fp is not None:
            self._fp.close()
            self._fp = None

    def write(self, record: dict[str, Any]) -> None:
        if self._fp is None:
            raise RuntimeError("JsonlWriter is not open")
        self._fp.write(json.dumps(record, separators=(",", ":")) + "\n")
        self._fp.flush()


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    k = (len(ordered) - 1) * (pct / 100)
    f = int(k)
    c = min(f + 1, len(ordered) - 1)
    if f == c:
        return ordered[f]
    return ordered[f] + (ordered[c] - ordered[f]) * (k - f)


def summarize(records: list[dict[str, Any]], wall_time_s: float) -> dict[str, Any]:
    latencies = [r["latency_ms"] for r in records]
    checksums = {r["checksum"] for r in records if r.get("checksum")}
    failures = [r for r in records if r["exit_code"] != 0]

    return {
        "runs": len(records),
        "failures": len(failures),
        "distinct_checksums": len(checksums),
        "checksum_ok": len(checksums) <= 1 and not failures,
        "p50_ms": round(percentile(latencies, 50), 1),
        "p95_ms": round(percentile(latencies, 95), 1),
        "p99_ms": round(percentile(latencies, 99), 1),
        "max_ms": round(max(latencies), 1) if latencies else 0,
        "throughput_per_sec": (
            round(len(records) / wall_time_s, 2) if wall_time_s > 0 else 0
        ),
    }


def run_level(concurrency: int, n: int, seed: int, run_one: RunOne) -> Iterator[dict[str, Any]]:
    """Yield each worker result as soon as that future finishes."""
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(run_one, n, seed) for _ in range(concurrency)]
        for future in as_completed(futures):
            yield future.result()


def run_suite(
    *,
    levels: list[int],
    n: int,
    seed: int,
    output: Path,
    run_one: RunOne,
) -> None:
    with JsonlWriter(output) as writer:
        for level in levels:
            start = time.monotonic()
            records: list[dict[str, Any]] = []

            for record in run_level(level, n, seed, run_one):
                writer.write({"type": "run", "concurrency": level, **record})
                records.append(record)

            wall_time_s = time.monotonic() - start
            summary = summarize(records, wall_time_s)
            writer.write({"type": "summary", "concurrency": level, **summary})
            print(json.dumps({"concurrency": level, **summary}))

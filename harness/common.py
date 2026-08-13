"""Shared concurrency harness helpers."""

from __future__ import annotations

import json
import time
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Self, TextIO

# One concurrent worker → one or more episode records (sandbox reuse).
RunWorker = Callable[[int, int], list[dict[str, Any]]]
# Back-compat alias for single-shot runners.
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
    latencies = [float(r["latency_ms"]) for r in records if "latency_ms" in r]
    warm_latencies = [
        float(r["latency_ms"])
        for r in records
        if "latency_ms" in r and r.get("cold") is False
    ]
    durations = [
        float(r["duration_ms"])
        for r in records
        if r.get("duration_ms") is not None
    ]
    checksums = {r["checksum"] for r in records if r.get("checksum")}
    failures = [r for r in records if r.get("exit_code", 0) != 0]
    runner_ids = {str(r["runner_id"]) for r in records if r.get("runner_id")}

    summary: dict[str, Any] = {
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
    if durations:
        summary["p50_duration_ms"] = round(percentile(durations, 50), 1)
        summary["p99_duration_ms"] = round(percentile(durations, 99), 1)
        summary["max_duration_ms"] = round(max(durations), 1)
    if warm_latencies:
        summary["p50_warm_ms"] = round(percentile(warm_latencies, 50), 1)
        summary["p99_warm_ms"] = round(percentile(warm_latencies, 99), 1)
    if runner_ids:
        summary["distinct_runners"] = len(runner_ids)
    return summary


def run_level(
    concurrency: int, n: int, seed: int, run_worker: RunWorker
) -> Iterator[dict[str, Any]]:
    """Yield each episode result as soon as that worker finishes."""
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(run_worker, n, seed) for _ in range(concurrency)]
        for future in as_completed(futures):
            for record in future.result():
                yield record


def run_suite(
    *,
    levels: list[int],
    n: int,
    seed: int,
    output: Path,
    run_worker: RunWorker,
    meta: dict[str, Any] | None = None,
) -> None:
    with JsonlWriter(output) as writer:
        if meta:
            writer.write({"type": "meta", **meta})
        for level in levels:
            start = time.monotonic()
            records: list[dict[str, Any]] = []

            for record in run_level(level, n, seed, run_worker):
                writer.write({"type": "run", "concurrency": level, **record})
                records.append(record)

            wall_time_s = time.monotonic() - start
            summary = summarize(records, wall_time_s)
            writer.write({"type": "summary", "concurrency": level, **summary})
            print(json.dumps({"concurrency": level, **summary}))

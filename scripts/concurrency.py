import argparse
import json
import subprocess
import time
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, TextIO, Self

IMAGE = "vera-agent-benchmark"


class JsonlWriter:
    """Append-only JSON Lines writer.

    Each call to write() serializes one Python object as a single line of JSON
    and flushes it to disk immediately. That means if the process crashes mid-
    run, everything written so far is still readable — unlike a final
    json.dump() that only happens at the end.
    """

    def __init__(self, path: Path) -> None:
        self._path = path
        self._fp: TextIO | None = None

    def __enter__(self) -> Self:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        # "w" truncates so each harness invocation starts a fresh file.
        self._fp = self._path.open("w", encoding="utf-8")
        return self

    def __exit__(self, *exc: object) -> None:
        if self._fp is not None:
            self._fp.close()
            self._fp = None

    def write(self, record: dict[str, Any]) -> None:
        if self._fp is None:
            raise RuntimeError("JsonlWriter is not open")
        # separators keep the line compact; one object == one line
        self._fp.write(json.dumps(record, separators=(",", ":")) + "\n")
        # flush + fsync so the line survives a kill/crash, not just an
        # interpreter buffer flush.
        self._fp.flush()


def run_one(n: int, seed: int) -> dict[str, Any]:
    start = time.monotonic()
    result = subprocess.run(
        [
            "docker", "run", "--rm",
            "--cpus=1", "--memory=1g",
            IMAGE, "--n", str(n), "--seed", str(seed),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    latency_ms = (time.monotonic() - start) * 1000

    record: dict[str, Any] = {
        "latency_ms": latency_ms,
        "exit_code": result.returncode,
    }
    if result.returncode == 0:
        try:
            payload = json.loads(result.stdout.strip())
            record["checksum"] = payload.get("checksum")
            record["duration_ms"] = payload.get("duration_ms")
        except json.JSONDecodeError:
            record["error"] = "invalid_json_output"
            record["stdout"] = result.stdout
    else:
        record["stderr"] = result.stderr

    return record


def run_level(concurrency: int, n: int, seed: int) -> Iterator[dict[str, Any]]:
    """Yield each container result as soon as that future finishes."""
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(run_one, n, seed) for _ in range(concurrency)]
        for future in as_completed(futures):
            yield future.result()


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


def main() -> None:
    parser = argparse.ArgumentParser(description="Vera concurrency test harness")
    parser.add_argument(
        "--levels", type=int, nargs="+", default=[1, 8, 22, 44, 88, 176]
    )
    parser.add_argument("--n", type=int, default=20)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output", type=str, default="concurrency_results.jsonl")
    args = parser.parse_args()

    with JsonlWriter(Path(args.output)) as writer:
        for level in args.levels:
            start = time.monotonic()
            records: list[dict[str, Any]] = []

            for record in run_level(level, args.n, args.seed):
                # Persist the raw run immediately; don't wait for the level
                # (or the whole suite) to finish.
                writer.write({"type": "run", "concurrency": level, **record})
                records.append(record)

            wall_time_s = time.monotonic() - start
            summary = summarize(records, wall_time_s)
            writer.write({"type": "summary", "concurrency": level, **summary})
            print(json.dumps({"concurrency": level, **summary}))


if __name__ == "__main__":
    main()

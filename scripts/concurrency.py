import argparse
import json
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

IMAGE = "vera-agent-benchmark"


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


def run_level(concurrency: int, n: int, seed: int) -> list[dict[str, Any]]:
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(run_one, n, seed) for _ in range(concurrency)]
        return [f.result() for f in as_completed(futures)]


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
    parser.add_argument("--output", type=str, default="concurrency_results.json")
    args = parser.parse_args()

    results = {}
    for level in args.levels:
        start = time.monotonic()
        records = run_level(level, args.n, args.seed)
        wall_time_s = time.monotonic() - start
        summary = summarize(records, wall_time_s)
        results[level] = {"summary": summary, "runs": records}

        print(json.dumps({"concurrency": level, **summary}))

    with open(args.output, "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()

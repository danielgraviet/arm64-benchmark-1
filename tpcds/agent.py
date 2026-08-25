"""TPC-DS benchmark entrypoint. Mirrors analytics/agent.py so the existing
harness and microVM sweeps can drive it with no changes."""

from __future__ import annotations

import argparse
import hashlib
import json
import time

from tpcds import pipeline


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="TPC-DS query benchmark (DuckDB)")
    p.add_argument("--n", type=int, default=2,
                   help="passes over the 99-query set (data size is fixed by "
                        "the fixture's scale factor)")
    p.add_argument("--seed", type=int, default=42,
                   help="accepted for harness compatibility; TPC-DS is "
                        "deterministic for a given scale factor")
    p.add_argument("--output", type=str, default="json", choices=["json"])
    return p.parse_args()


def compute_checksum(*parts: object) -> str:
    h = hashlib.sha256()
    for part in parts:
        h.update(json.dumps(part, sort_keys=True, default=str).encode("utf-8"))
    return h.hexdigest()


def main() -> None:
    args = parse_args()
    t0 = time.perf_counter()
    result = pipeline.run(args.n, args.seed)
    duration_ms = int((time.perf_counter() - t0) * 1000)
    print(json.dumps({
        "task": result["task"],
        "iterations": args.n,
        "duration_ms": duration_ms,
        "scale_factor": result["scale_factor"],
        "rows_returned": result["rows_returned"],
        "checksum": compute_checksum(result["query_digests"],
                                     result["queries_per_pass"],
                                     result["scale_factor"]),
    }))


if __name__ == "__main__":
    main()

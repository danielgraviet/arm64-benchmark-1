"""TPC-DS query pipeline: the analytics replacement that actually uses cores.

Why this exists
---------------
The original `analytics` benchmark generates its data with pure-Python list
comprehensions, which the GIL serialises. Measured in microVMs it is ~84%
serial: giving it 4 vCPUs instead of 1 buys 13%. That makes it useless for
comparing multi-core hardware, which was the whole point.

This module keeps the same harness contract (`run(n, seed) -> dict`, one JSON
line, deterministic checksum) but:

  * the dataset is a FIXTURE built once at image-build time, so no generation
    cost lands inside the measurement at all;
  * the timed work is DuckDB's 99 standard TPC-DS queries, executed by its own
    C++ parallel engine. Measured on Graviton5 at sf=10 that scales 3.53x on
    4 threads and 10.96x on 16, against the old benchmark's 1.13x on 4.

`--n` scales passes over the query set, so duration is tunable without
changing the data size or the cache behaviour.
"""

from __future__ import annotations

import hashlib
import os
from decimal import Decimal
from typing import Any

import duckdb

SCALE_FACTOR = float(os.environ.get("TPCDS_SF", "1"))
FIXTURE = os.environ.get("TPCDS_DB", "/app/tpcds/tpcds.duckdb")
# DuckDB sizes its thread pool from the MACHINE cpu count and pins its own
# workers, so it ignores taskset/numactl. Inside a microVM that is fine (it
# only sees the vCPUs it was given); natively you need this knob to vary
# parallelism at all.
THREADS = os.environ.get("TPCDS_THREADS")
QUERIES = tuple(range(1, 100))
ROUND_DP = 6


def _stable(v: Any) -> Any:
    """Round floats so BLAS/platform summation order cannot change the checksum."""
    if isinstance(v, Decimal):
        return round(float(v), ROUND_DP)
    if isinstance(v, float):
        return round(v, ROUND_DP)
    return v


def run(n: int, seed: int) -> dict[str, Any]:
    if n < 1:
        raise ValueError("n (query-set passes) must be >= 1")
    if not os.path.exists(FIXTURE):
        raise RuntimeError(
            f"TPC-DS fixture not found at {FIXTURE}. Build it with "
            f"build_fixtures.py (or set TPCDS_DB)."
        )

    cfg = {"threads": int(THREADS)} if THREADS else {}
    con = duckdb.connect(FIXTURE, read_only=True, config=cfg)
    con.execute("LOAD tpcds")

    rows_seen = 0
    per_query: list[str] = []
    for _ in range(n):
        for q in QUERIES:
            rows = con.execute(f"PRAGMA tpcds({q})").fetchall()
            rows_seen += len(rows)
            # Sort before hashing: DuckDB may return rows in a different order
            # under different thread counts, and the checksum must not depend
            # on how parallel the run was.
            norm = sorted(repr(tuple(_stable(c) for c in r)) for r in rows)
            per_query.append(hashlib.sha256("".join(norm).encode()).hexdigest())
    con.close()

    return {
        "task": "tpcds-queries-v1",
        "passes": n,
        "scale_factor": SCALE_FACTOR,
        "queries_per_pass": len(QUERIES),
        "rows_returned": rows_seen,
        "query_digests": per_query[:len(QUERIES)],
    }

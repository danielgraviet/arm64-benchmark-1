#!/usr/bin/env python3
"""Build the TPC-H / TPC-DS fixtures the benchmarks query.

Run this once at image-build time. Generation is deliberately OUTSIDE the
measured region -- that is the whole point of replacing the old analytics
benchmark, whose pure-Python generation phase was ~84% of its runtime and
serial.
"""

from __future__ import annotations

import argparse
import os
import time

import duckdb

SPECS = {
    "tpch": ("INSTALL tpch; LOAD tpch;", "CALL dbgen(sf={sf})"),
    "tpcds": ("INSTALL tpcds; LOAD tpcds;", "CALL dsdgen(sf={sf})"),
}


def build(kind: str, sf: float, out: str) -> None:
    setup, gen = SPECS[kind]
    if os.path.exists(out):
        os.remove(out)
    t0 = time.time()
    con = duckdb.connect(out)
    con.execute(setup)
    con.execute(gen.format(sf=sf))
    tables = con.execute(
        "select count(*) from duckdb_tables()").fetchone()[0]
    con.close()
    size = os.path.getsize(out)
    print(f"  {kind:6} sf={sf:<5} {tables:>3} tables  {size / 1e6:>8.1f} MB  "
          f"{time.time() - t0:>6.1f}s  -> {out}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kinds", default="tpch,tpcds")
    ap.add_argument("--sf", type=float, default=1.0)
    ap.add_argument("--dir", default=".")
    args = ap.parse_args()
    print(f"building fixtures at scale factor {args.sf}")
    for kind in args.kinds.split(","):
        build(kind, args.sf, os.path.join(args.dir, kind, f"{kind}.duckdb"))


if __name__ == "__main__":
    main()

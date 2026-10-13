"""Median create-ready table for the OCI Vera shared vs split arms."""

import collections
import glob
import json
import os
import statistics as st

root = os.environ.get("BENCH_DIR", "/home/ubuntu/arm64-benchmark-1").rstrip("/") + "/"
logdir = os.environ.get("LOGDIR") or (
    "/mnt/data/bench-logs" if os.path.isdir("/mnt/data/bench-logs") else "/root/bench-logs"
)


def qtile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(p * len(ordered)))]


runs = collections.defaultdict(dict)
for path in sorted(glob.glob(logdir + "/vera-*-20*.log")):
    if path.endswith(".raw"):
        continue
    for line in open(path, encoding="utf-8", errors="replace"):
        if not line.startswith("FILE"):
            continue
        parts = line.split()
        if len(parts) < 6:
            continue
        _, arm, n, _rep, _rc, filename = parts[:6]
        runs[(arm, int(n))][filename] = 1

print(
    f"{'N':>5} {'arm':9} {'runs':>4} {'fail':>4} "
    f"{'p25 s':>7} {'p50 s':>7} {'p95 s':>7} {'accept p50':>10} {'wait p50':>9} "
    f"{'all ready s (median [min-max])':>31}"
)
for n in (1, 10, 100, 1000, 2000):
    for arm in ("A-shared", "B-split"):
        files = list(runs.get((arm, n), {}))
        if not files:
            continue
        series = []
        for filename in files:
            rows = [json.loads(line) for line in open(root + filename, encoding="utf-8")]
            ok = [row for row in rows if row.get("type") == "sandbox" and row.get("status") == "ok"]
            count = sum(1 for row in rows if row.get("type") == "sandbox")
            creates = [row["create_s"] for row in ok if row.get("create_s") is not None]
            summaries = [row for row in rows if row.get("type") == "summary"]
            if summaries and summaries[0].get("ready_wall_s") is not None:
                wall = summaries[0]["ready_wall_s"]
            elif creates:
                wall = max(creates)
            else:
                wall = 0.0
            series.append(
                {
                    "fail": count - len(ok),
                    "p25": qtile(creates, 0.25),
                    "p50": qtile(creates, 0.5),
                    "p95": qtile(creates, 0.95),
                    "wall": wall,
                    "post": qtile([row.get("post_s") or 0 for row in ok], 0.5),
                    "wait": qtile([row.get("wait_s") or 0 for row in ok], 0.5),
                }
            )
        def median(key, series=series):
            return st.median(row[key] for row in series)

        walls = [row["wall"] for row in series]
        print(
            f"{n:>5} {arm:9} {len(series):>4} {sum(row['fail'] for row in series):>4} "
            f"{median('p25'):>7.2f} {median('p50'):>7.2f} {median('p95'):>7.2f} "
            f"{median('post'):>10.2f} {median('wait'):>9.2f} "
            f"{st.median(walls):>12.2f} [{min(walls):.2f}-{max(walls):.2f}]"
        )

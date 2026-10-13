#!/usr/bin/env python3
"""Summarise a per-core probe directory. Work phase only."""

import collections
import json
import os
import statistics as st
import sys

probe_dir = sys.argv[1]
runs = {}
for line in open(os.path.join(probe_dir, "runs.txt"), encoding="utf-8"):
    parts = line.split()
    if len(parts) < 3:
        continue
    if parts[1] == "end":
        runs[parts[0]]["end"] = float(parts[2])
    else:
        runs[parts[0]] = {
            "level": int(parts[1]),
            "cores": int(parts[2]),
            "start": float(parts[3]),
        }


def perf_rows(path):
    out = []
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        stamp = float(row.get("interval", 0))
        try:
            out.append((stamp, row.get("event", ""), float(row.get("counter-value", ""))))
        except (TypeError, ValueError):
            pass
        metric_value = row.get("metric-value")
        metric_unit = (row.get("metric-unit") or "").strip()
        if metric_value not in (None, "") and metric_unit:
            try:
                out.append((stamp, "M:" + metric_unit.split()[-1], float(metric_value), metric_unit))
            except (TypeError, ValueError):
                pass
    return out


def windows(tag, level):
    path = os.path.join(probe_dir, f"{tag}.host.txt")
    if not os.path.exists(path):
        return None
    rows = []
    for line in open(path, encoding="utf-8"):
        parts = line.split()
        if len(parts) != 4:
            continue
        rows.append((float(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])))
    ok = [row for row in rows if row[1] >= 0.98 * level]
    if len(ok) < 2:
        return None
    return ok[0], ok[-1]


def pick(table, *names):
    for name in names:
        for key, values in table.items():
            if key.lower() == name:
                return st.mean(values)
    return None


print(
    f"{'run':3} {'level':>5} {'cores':>5} {'fail':>4} {'thr/s':>6} {'job s':>6} "
    f"{'core-s/job':>10} {'IPC':>5} {'GHz':>5} {'backend':>8} {'mem-bound':>9} "
    f"{'frontend':>8} {'retiring':>8} {'DRAM GB/s':>9} {'win':>4}"
)
result = {}
for tag in ("L", "P", "H"):
    if tag not in runs:
        continue
    spec = runs[tag]
    records = [
        json.loads(line)
        for line in open(os.path.join(probe_dir, f"{tag}.jsonl"), encoding="utf-8")
    ]
    summary = next((row for row in records if row.get("type") == "summary"), {})
    ok_runs = [
        row
        for row in records
        if row.get("type") == "run" and row.get("exit_code") == 0 and row.get("duration_ms")
    ]
    throughput = summary.get("throughput_per_sec") or 0
    job = st.mean(row["duration_ms"] for row in ok_runs) / 1000 if ok_runs else float("nan")
    span = windows(tag, spec["level"])
    ipc = ghz = None
    stalls = collections.defaultdict(list)
    bandwidth = []
    nwin = 0
    if span:
        (t0, _, busy0, _), (t1, _, busy1, _) = span
        lo, hi = t0 - spec["start"], t1 - spec["start"]
        base = [
            row
            for row in perf_rows(os.path.join(probe_dir, f"{tag}.ipc.json"))
            if lo <= row[0] <= hi
        ]
        cycles = sum(row[2] for row in base if str(row[1]).startswith("cycles"))
        instructions = sum(row[2] for row in base if str(row[1]).startswith("instructions"))
        nwin = len({row[0] for row in base})
        busy_s = (busy1 - busy0) / os.sysconf("SC_CLK_TCK")
        ipc = instructions / cycles if cycles else None
        ghz = cycles / busy_s / 1e9 if busy_s > 0 else None
        for name in ("td", "td2"):
            for row in perf_rows(os.path.join(probe_dir, f"{tag}.{name}.json")):
                if len(row) == 4 and lo <= row[0] <= hi:
                    stalls[row[1][2:]].append(row[2])
        for row in perf_rows(os.path.join(probe_dir, f"{tag}.bw.json")):
            if len(row) == 4 and lo <= row[0] <= hi:
                bandwidth.append((row[0], row[2], row[3]))
    backend = pick(stalls, "backend_bound")
    memory = pick(stalls, "backend_bound_by_memory", "backend_memory_bound", "memory_bound")
    frontend = pick(stalls, "frontend_bound")
    retiring = pick(stalls, "retiring")
    gbs = None
    if bandwidth:
        per_tick = collections.defaultdict(float)
        for stamp, value, unit in bandwidth:
            per_tick[stamp] += value / (1000 if unit.lower().startswith("mb") else 1)
        gbs = st.mean(per_tick.values())
    core_seconds = spec["cores"] / throughput if throughput else float("nan")
    result[tag] = {"cs": core_seconds, "job": job, "ipc": ipc, "ghz": ghz}

    def fmt(value, pattern):
        return (pattern % value) if value is not None else "-"

    print(
        f"{tag:3} {spec['level']:>5} {spec['cores']:>5} {summary.get('failures', 0):>4} "
        f"{throughput:>6.2f} {job:>6.1f} {core_seconds:>10.2f} {fmt(ipc, '%5.2f'):>5} "
        f"{fmt(ghz, '%5.2f'):>5} {fmt(backend, '%7.1f%%'):>8} {fmt(memory, '%8.1f%%'):>9} "
        f"{fmt(frontend, '%7.1f%%'):>8} {fmt(retiring, '%7.1f%%'):>8} {fmt(gbs, '%9.1f'):>9} {nwin:>4}"
    )

if {"L", "P", "H"} <= result.keys() and result["L"]["job"]:
    light, packed, half = result["L"], result["P"], result["H"]
    print(f"\npacked slowdown (core-s/job P vs per-job time L): {packed['cs'] / light['job']:.2f}x")
    print(f"half-socket packed (H) vs full-socket packed (P): core-s/job {half['cs']:.2f} vs {packed['cs']:.2f}")
    if light["ipc"] and packed["ipc"]:
        print(
            f"IPC light -> packed: {light['ipc']:.2f} -> {packed['ipc']:.2f} "
            f"({100 * (packed['ipc'] / light['ipc'] - 1):+.0f}%)"
        )
    if light["ghz"] and packed["ghz"]:
        print(
            f"clock light -> packed: {light['ghz']:.2f} -> {packed['ghz']:.2f} GHz "
            f"({100 * (packed['ghz'] / light['ghz'] - 1):+.0f}%)"
        )

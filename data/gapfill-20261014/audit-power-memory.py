"""Read saved run archives; validate memory arithmetic and summarize power scopes.

No host access, extraction, or benchmark execution. The JSON output is the evidence
behind the v3 report. Run with the output path as the sole argument.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import statistics as stats
import sys
import tarfile

DATA = Path(__file__).resolve().parent.parent
SPECS = {
    "vera": (
        "vera-hq-cell-20261014/power-mem-20261015/vera-power-mem.tgz",
        "mem-vera-20261015_143002",
        "power-vera-20261015_130420",
    ),
    "epyc9575": (
        "vera-hq-cell-20261014/power-mem-20261015/epyc9575-power-mem.tgz",
        "mem-epyc9575-20261015_150022",
        "power-epyc9575-20261015_130401",
    ),
    "graviton5": (
        "graviton5-cell-20261014/mem-ladder-20261015.tgz",
        "mem-graviton5-20261015_130901",
        None,
    ),
}


def rows(text):
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def samples(text):
    lines = [line for line in text.splitlines() if line and not line.startswith("#")]
    keys = lines[0].split("\t")
    return [dict(zip(keys, map(float, line.split("\t")))) for line in lines[1:]]


def avg(values):
    values = [v for v in values if math.isfinite(v)]
    return round(stats.mean(values), 3) if values else None


def scopes(sample_rows):
    out = {}
    for label, prefix in (
        ("vera_AP_W", "vera_ap_"),
        ("vera_Total_W", "vera_total_"),
        ("vera_DRAM_W", "vera_dram_"),
        ("AMD_package_W", "rapl_pkg_"),
    ):
        vals = []
        for row in sample_rows:
            parts = [v for k, v in row.items() if k.startswith(prefix)]
            if parts:
                vals.append(sum(parts))
        if vals:
            out[label] = avg(vals)
    for key in ("wall_w", "busy_ghz"):
        out[key] = avg([r.get(key, math.nan) for r in sample_rows])
    out["samples"] = len(sample_rows)
    return out


def power(idle_text, sample_text, jsonl_text):
    telemetry = samples(sample_text)
    summaries = [r for r in rows(jsonl_text) if r.get("type") == "summary"]
    out = {"idle": scopes(samples(idle_text)), "levels": []}
    for i, summary in enumerate(summaries):
        ends = [r["t"] for r in telemetry if r["nsum"] >= i + 1]
        entry = {k: summary.get(k) for k in (
            "concurrency", "runs", "failures", "checksum_ok",
            "throughput_per_sec", "exec_wall_s", "p50_duration_ms",
        )}
        if ends:
            # Same approximate exec-window convention as the saved kit report.
            end = ends[0]
            window = [r for r in telemetry if end - summary["exec_wall_s"] <= r["t"] < end]
            entry["scopes"] = scopes(window)
        else:
            entry["scopes"] = None
        out["levels"].append(entry)
    return out


result = {"hosts": {}, "notes": [
    "Logical triad traffic, not hardware DRAM counters or an official STREAM submission.",
    "Power scopes are intentionally separate; Vera AP is not AMD package power.",
    "Power exec windows are inferred from sampled summary arrival; not exact energy markers.",
    "Host RPC timing bounds overlap; it does not timestamp kernel entry inside each guest.",
]}
for host, (rel, memdir, powerdir) in SPECS.items():
    path = DATA / rel
    entry = {"archive": rel, "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest()}
    with tarfile.open(path) as archive:
        def text(name):
            with archive.extractfile(name) as stream:
                return stream.read().decode()

        source = text(f"{memdir}/memtest.c")
        harness = text(f"{memdir}/memfleet.py")
        entry["memtest_sha256"] = hashlib.sha256(source.encode()).hexdigest()
        entry["compile_commands"] = [line.strip() for line in harness.splitlines() if "gcc " in line]
        entry["memory"] = []
        for member in archive.getmembers():
            match = re.fullmatch(re.escape(memdir) + r"/c(\d+)-r(\d+)\.jsonl", member.name)
            if not match:
                continue
            records = rows(text(member.name))
            meta = next(r for r in records if r.get("type") == "meta")
            summary = next(r for r in records if r.get("type") == "summary")
            ok = [r for r in records if r.get("type") == "sandbox" and r.get("status") == "ok"]
            failures = [r for r in records if r.get("type") == "sandbox" and r.get("status") != "ok"]
            assert len(ok) == summary["ok"]
            assert len(failures) == summary["failed"]
            assert summary["count"] == len(ok) + len(failures)
            assert abs(sum(r["mean_gbs"] for r in ok) - summary["aggregate_gbs"]) <= 0.011
            for row in ok:
                assert row["n"] == 2**24
                # Rounded duration and bandwidth can cause a small discrepancy.
                rate = row["passes"] * 3 * row["n"] * 8 / (row["duration_ms"] / 1000) / 1e9
                assert abs(rate - row["mean_gbs"]) < max(0.002, rate * 0.00002)
                expected = math.ceil(row["n"] / 4096) * (3.5 if row["passes"] % 2 else 6.5)
                assert row["checksum"] == expected
            a = max(r["t_exec_send"] for r in ok)
            b = min(r["t_exec_done"] for r in ok)
            # If a kernel ran for D seconds inside [send, done], its start is no
            # later than done-D and its end is no earlier than send+D.
            guaranteed = min(r["t_exec_send"] + r["duration_ms"] / 1000 for r in ok) - max(
                r["t_exec_done"] - r["duration_ms"] / 1000 for r in ok)
            sampled = samples(text(member.name + ".samp"))
            entry["memory"].append({
                "concurrency": int(match[1]), "rep": int(match[2]),
                "image": meta["image"], "ok": len(ok), "failed": len(failures),
                "failure_statuses": [r["status"] for r in failures],
                "aggregate_GBs": summary["aggregate_gbs"],
                "host_send_skew_s": round(a - min(r["t_exec_send"] for r in ok), 4),
                "host_rpc_overlap_s": round(b - a, 4),
                "conservative_kernel_overlap_s": round(guaranteed, 4),
                "max_rpc_minus_kernel_s": round(max(
                    r["t_exec_done"] - r["t_exec_send"] - r["duration_ms"] / 1000 for r in ok), 4),
                "duration_s_range": [min(r["duration_ms"] for r in ok) / 1000,
                                     max(r["duration_ms"] for r in ok) / 1000],
                "power_host_window": scopes([r for r in sampled if a + 3 <= r["t"] <= b - 3]),
            })
        entry["memory"].sort(key=lambda r: (r["concurrency"], r["rep"]))
        entry["requested_sandboxes"] = sum(r["ok"] + r["failed"] for r in entry["memory"])
        entry["setup_failures"] = sum(r["failed"] for r in entry["memory"])
        if powerdir:
            entry["power"] = power(text(f"{powerdir}/idle.samp"),
                                   text(f"{powerdir}/ladder.samp"), text(f"{powerdir}/ladder.jsonl"))
    result["hosts"][host] = entry

turin = DATA / "phoenix-e6-cell-20261014/power-mem"
result["hosts"]["turin"] = {"memory": None, "power": power(
    (turin / "idle.samp").read_text(), (turin / "ladder.samp").read_text(),
    (turin / "ladder.jsonl").read_text())}
assert len({v["memtest_sha256"] for v in result["hosts"].values() if "memtest_sha256" in v}) == 1
Path(sys.argv[1]).write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
for host, entry in result["hosts"].items():
    print(host)
    if entry["memory"]:
        print("  memory: requested", entry["requested_sandboxes"], "failed", entry["setup_failures"])
        for row in entry["memory"]:
            print(" ", row["concurrency"], row["rep"], f"{row['ok']} ok/{row['failed']} failed",
                  row["aggregate_GBs"], "GB/s; guaranteed overlap", row["conservative_kernel_overlap_s"], "s")
    if "power" in entry:
        for row in entry["power"]["levels"]:
            print("  power", row["concurrency"], row["throughput_per_sec"], "jobs/s", row["failures"],
                  "failed", row["scopes"])

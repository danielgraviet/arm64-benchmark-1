#!/usr/bin/env python3
"""mem-report.py OUTDIR -> markdown: per concurrency level, aggregate GB/s (sum of concurrent per-sandbox triad rates),
per-sandbox GB/s, start skew / overlap, mean power during the overlap window, GB/s per W, busy-core clock."""
import glob, json, math, os, re, sys
d = sys.argv[1]
def samp(p):
    hdr = None; rows = []
    if not os.path.exists(p): return rows
    for l in open(p):
        if l.startswith("#"): continue
        f = l.rstrip("\n").split("\t")
        if hdr is None: hdr = f; continue
        rows.append({k: (float(v) if v not in ("nan", "") else math.nan) for k, v in zip(hdr, f)})
    return rows
def mean(xs):
    xs = [x for x in xs if not math.isnan(x)]; return sum(xs) / len(xs) if xs else math.nan
print("# Memory-bandwidth ladder (STREAM-style triad, one vCPU per sandbox)\n")
print("| sandboxes | rep | ok | aggregate GB/s | per-sandbox GB/s p50 / min | start skew s | overlap s | processor W | GB/s per W | busy GHz |")
print("|---|---|---|---|---|---|---|---|---|---|")
def key(f):
    m = re.search(r"c(\d+)-r(\d+)\.jsonl$", f); return (int(m.group(1)), int(m.group(2)))
for f in sorted(glob.glob(f"{d}/c*-r*.jsonl"), key=key):
    S = [json.loads(l) for l in open(f) if '"summary"' in l]
    if not S: print(f"| {key(f)[0]} | {key(f)[1]} | no summary |"); continue
    s = S[-1]; c, r = key(f)
    rows = [x for x in samp(f + ".samp") if s.get("t_first_start") and s["t_first_start"] + 3 <= x["t"] <= s["t_last_end"] - 3]
    pw = mean([sum(v for k, v in x.items() if k.startswith(("vera_ap_", "rapl_pkg_"))) or math.nan for x in rows])
    g = mean([x["busy_ghz"] for x in rows])
    print(f"| {c} | {r} | {s['ok']}/{s['count']} | {s['aggregate_gbs']} | {s['per_sandbox_gbs_p50']} / {s['per_sandbox_gbs_min']} | "
          f"{s['start_skew_s']} | {s['overlap_s']} | {pw:.0f} | {s['aggregate_gbs']/pw if pw == pw and pw else math.nan:.3f} | {g:.2f} |")
print("\nAggregate GB/s is the sum of per-sandbox mean triad rates and is valid only when start skew is small against the run length"
      " (overlap ≈ run length). STREAM convention: 3 × 8 bytes per element per pass; write-allocate traffic is not counted.")

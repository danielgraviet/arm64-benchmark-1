#!/usr/bin/env python3
"""power-report.py IDLE.samp LADDER.samp LADDER.jsonl -> markdown: per level jobs/s, mean power per domain, jobs/s per W, J per job,
busy-core clock. Exec window of level k = the last exec_wall_s seconds before the (k+1)-th summary line appeared."""
import json, math, sys
def load(p):
    hdr = None; rows = []; meta = ""
    for l in open(p):
        if l.startswith("#"): meta = l.strip(); continue
        f = l.rstrip("\n").split("\t")
        if hdr is None: hdr = f; continue
        rows.append({k: (float(v) if v not in ("nan", "") else math.nan) for k, v in zip(hdr, f)})
    return hdr, rows, meta
def mean(xs):
    xs = [x for x in xs if not math.isnan(x)]; return sum(xs) / len(xs) if xs else math.nan
hi, idle, imeta = load(sys.argv[1]); hl, lad, lmeta = load(sys.argv[2])
S = [json.loads(l) for l in open(sys.argv[3]) if '"summary"' in l]
dom = [h for h in hl if h.startswith(("vera_", "rapl_")) or h == "wall_w"]
# scopes: processor ~ Vera AP power vs AMD RAPL package (neither includes DRAM); module = Vera Total (incl. on-module LPDDR)
def scopes(r):
    o = {}
    ap = [r[k] for k in r if k.startswith("vera_ap_")]; tot = [r[k] for k in r if k.startswith("vera_total_")]
    pkg = [r[k] for k in r if k.startswith("rapl_pkg_")]; dram = [r[k] for k in r if k.startswith("vera_dram_")]
    if ap: o["processor_w"] = sum(ap)
    if pkg: o["processor_w"] = sum(pkg)
    if tot: o["module_w"] = sum(tot)
    if dram: o["dram_w"] = sum(dram)
    if "wall_w" in r and not math.isnan(r["wall_w"]): o["wall_w"] = r["wall_w"]
    return o
def win_means(rows):
    sc = [scopes(r) for r in rows]; keys = sorted({k for s in sc for k in s})
    return {k: mean([s.get(k, math.nan) for s in sc]) for k in keys}, mean([r["busy_ghz"] for r in rows]), mean([r["busy_cpus"] for r in rows])
I, ig, _ = win_means(idle)
print(f"# Jobs per watt\n\nsampler: {lmeta}\n\nIdle ({len(idle)} samples): " + ", ".join(f"{k} {v:.0f} W" for k, v in I.items()) + "\n")
print("| level | jobs/s | failures | " + " | ".join(f"{k} (W)" for k in I) + " | jobs/s per processor W ×1000 | J per job (processor) | J per job above idle | busy-core GHz | busy CPUs |")
print("|" + "---|" * (8 + len(I)))
for k, s in enumerate(S):
    ends = [r["t"] for r in lad if r["nsum"] >= k + 1]
    if not ends: continue
    tend = ends[0]; rows = [r for r in lad if tend - s["exec_wall_s"] <= r["t"] < tend]
    M, g, bc = win_means(rows); tp = s["throughput_per_sec"]; pw = M.get("processor_w", math.nan)
    print(f"| {s['concurrency']} | {tp} | {s['failures']} | " + " | ".join(f"{M.get(x, math.nan):.0f}" for x in I) +
          f" | {1000*tp/pw:.1f} | {pw/tp:.1f} | {(pw-I.get('processor_w', 0))/tp:.1f} | {g:.2f} | {bc:.0f} |")
print("\nprocessor_w = Vera 'AP Power' (both sockets) or AMD RAPL package (both sockets); module_w = Vera 'Total Power' incl. on-module memory;"
      " wall_w = BMC reading if available. Confirm the Vera domain definitions before quoting; AMD RAPL excludes DRAM.")

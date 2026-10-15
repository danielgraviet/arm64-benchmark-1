"""Supplementary to the kit's mem-report.py (unchanged): mean power during each memory run, with the window taken from
memfleet's HOST-side timestamps (t_exec_send / t_exec_done) instead of memtest's guest CLOCK_REALTIME stamps.
On HQ Vera the guest wall clock is hours behind (daytona/rlp#767), so the kit's guest-time window misses every host
sample and the report shows nan. usage: mem-power.py <mem-run-dir>"""
import glob, json, math, re, sys
d = sys.argv[1]
def samp(p):
    h = None; rows = []
    try:
        for l in open(p):
            if l.startswith("#"): continue
            f = l.rstrip("\n").split("\t")
            if h is None: h = f; continue
            rows.append({k: (float(v) if v not in ("nan", "") else math.nan) for k, v in zip(h, f)})
    except FileNotFoundError: pass
    return rows
def mean(xs):
    xs = [x for x in xs if not math.isnan(x)]; return sum(xs) / len(xs) if xs else math.nan
def key(f):
    m = re.search(r"c(\d+)-r(\d+)\.jsonl$", f); return (int(m.group(1)), int(m.group(2)))
print("| sandboxes | rep | ok | aggregate GB/s | guest clock - host (s) | host send skew s | host window s | processor W | module W | DRAM W | wall W | GB/s per processor W | busy GHz |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for f in sorted(glob.glob(f"{d}/c*-r*.jsonl"), key=key):
    recs = [json.loads(l) for l in open(f)]
    s = recs[-1]; ok = [r for r in recs if r.get("type") == "sandbox" and r.get("status") == "ok"]
    if not ok: print(f"| {key(f)[0]} | {key(f)[1]} | 0/{s['count']} | — |"); continue
    off = mean([r["t_start"] - r["t_exec_send"] for r in ok])
    a = max(r["t_exec_send"] for r in ok) + 3; b = min(r["t_exec_done"] for r in ok) - 3
    rows = [x for x in samp(f + ".samp") if a <= x["t"] <= b]
    def dom(prefixes): return mean([sum(v for k, v in x.items() if k.startswith(prefixes)) or math.nan for x in rows])
    pw = dom(("vera_ap_", "rapl_pkg_")); mw = dom(("vera_total_",)); dw = dom(("vera_dram_",))
    ww = mean([x.get("wall_w", math.nan) for x in rows]); g = mean([x["busy_ghz"] for x in rows])
    skew = max(r["t_exec_send"] for r in ok) - min(r["t_exec_send"] for r in ok)
    fmt = lambda v: f"{v:.0f}" if v == v else "—"
    print(f"| {key(f)[0]} | {key(f)[1]} | {s['ok']}/{s['count']} | {s['aggregate_gbs']} | {off:.0f} | {skew:.2f} | {b-a:.0f} | {fmt(pw)} | {fmt(mw)} | {fmt(dw)} | {fmt(ww)} | "
          f"{(s['aggregate_gbs']/pw) if pw == pw and pw else math.nan:.2f} | {g:.2f} |")

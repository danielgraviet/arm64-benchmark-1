import sys, glob, statistics as st
f = sorted(glob.glob("/mnt/data/bench/vera-meters-*.tsv"))[-1]
names = open(f).readline().strip()[4:].split("|")[1:] if False else open(f).readline().strip().split("|")[1:]
rows = []
for l in open(f):
    if l.startswith("#"): continue
    p = l.split()
    if len(p) != len(names) + 1: continue
    rows.append([float(p[0])] + [float(x) for x in p[1:]])
idx = {n: i + 1 for i, n in enumerate(names)}
def col(r, n): return r[idx[n]] / 1e6
def s(sock):
    return {k: f"{k} in uW socket {sock}" for k in ("Total Power", "AP Power", "CPU Rail Power", "SOC Rail Power", "DRAM Power", "CPU Rail Output Power")}
D = sorted(glob.glob("/mnt/data/bench/power-vera-*"))[-1]
# windows: idle = first 180 s of idle.samp; plateau = level 2000 exec window from ladder.samp nsum
def samp(p):
    h = None; out = []
    for l in open(p):
        if l.startswith("#"): continue
        x = l.rstrip("\n").split("\t")
        if h is None: h = x; continue
        out.append(dict(zip(h, x)))
    return out
idle = samp(D + "/idle.samp"); lad = samp(D + "/ladder.samp")
wins = {"idle": (float(idle[0]["t"]), float(idle[-1]["t"]))}
import json
S = [json.loads(l) for l in open(D + "/ladder.jsonl") if '"summary"' in l]
for k, sm in enumerate(S):
    ends = [float(r["t"]) for r in lad if int(r["nsum"]) >= k + 1]
    if ends: wins[f"c{sm['concurrency']}"] = (ends[0] - sm["exec_wall_s"], ends[0])
print(f"{'window':7s} {'sock':4s} {'Total':>7s} {'AP':>7s} {'CPUrail':>8s} {'SOC':>6s} {'DRAM':>6s} {'CPUout':>7s} | {'AP-(cpu+soc+dram)':>17s} {'Total-AP':>8s} {'out/in':>6s} {'Tot max':>7s}")
for w, (a, b) in wins.items():
    rr = [r for r in rows if a <= r[0] <= b]
    if not rr: continue
    for sock in (0, 1):
        m = s(sock); v = {k: st.mean(col(r, n) for r in rr) for k, n in m.items()}
        tmax = max(col(r, m["Total Power"]) for r in rr)
        print(f"{w:7s} s{sock:<3d} {v['Total Power']:7.0f} {v['AP Power']:7.0f} {v['CPU Rail Power']:8.0f} {v['SOC Rail Power']:6.0f} {v['DRAM Power']:6.0f} {v['CPU Rail Output Power']:7.0f} | "
              f"{v['AP Power']-v['CPU Rail Power']-v['SOC Rail Power']-v['DRAM Power']:17.0f} {v['Total Power']-v['AP Power']:8.0f} {v['CPU Rail Output Power']/v['CPU Rail Power']:6.2f} {tmax:7.0f}")

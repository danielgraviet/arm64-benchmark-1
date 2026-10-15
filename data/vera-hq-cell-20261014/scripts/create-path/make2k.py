import json, sys, glob, re
d = sorted(glob.glob(f"/mnt/data/bench/run2k-{sys.argv[1]}-*"))[-1] + "/"
def q(v, p): v = sorted(v); return round(v[min(len(v)-1, int(p*len(v)))], 3) if v else None
log = open(d + "log").read()
out = {"raw_dir": d, "startup_2000": {}, "monitor": {}}
for img, reps in (("idle", (1, 2, 3)), ("agent", (1, 2))):
    runs = []
    for rep in reps:
        try:
            recs = [json.loads(l) for l in open(f"{d}startup-{img}-{rep}.jsonl")]
            s = recs[-1]; c = [r["create_s"] for r in recs if r.get("type") == "sandbox" and r.get("status") == "ok"]
            runs.append({"rep": rep, "ok": s["ok"], "failed": s["failed"], "all_ready_s": round(s["ready_wall_s"], 2),
                         "create_p50_s": q(c, .5), "create_p90_s": q(c, .9), "create_p95_s": q(c, .95), "create_p99_s": q(c, .99)})
        except Exception:
            runs.append({"rep": rep, "result": "no summary: client killed by the 1200 s outer timeout (a sandbox never answered)"})
    out["startup_2000"][img] = runs
for l in open(d + "tput-2000.jsonl"):
    r = json.loads(l)
    if r.get("type") == "summary":
        out["throughput_2000"] = {"runs": r["runs"], "failures": r["failures"], "jobs_per_s": r["throughput_per_sec"],
                                  "p50_s": round(r["p50_ms"]/1000, 1), "p95_s": round(r["p95_ms"]/1000, 1),
                                  "p99_s": round(r["p99_ms"]/1000, 1), "max_s": round(r["max_ms"]/1000, 1)}
for m in re.findall(r"peak host mem used (\d+) of (\d+) GiB .*?baseline (\d+) GiB; peak load (\d+)", log):
    pass
mons = re.findall(r"STARTUP2K image=(\w+) rep=(\d).*?\n.*?peak host mem used (\d+) of (\d+) GiB \((\d+)%\), baseline (\d+) GiB; peak load (\d+)", log)
for img, rep, used, tot, pct, base, load in mons:
    out["monitor"][f"startup-{img}-{rep}"] = {"peak_mem_used_gib": int(used), "mem_total_gib": int(tot), "baseline_gib": int(base), "peak_load": int(load)}
t = re.search(r"TPUT2K.*?\n.*?peak host mem used (\d+) of (\d+) GiB \((\d+)%\), baseline (\d+) GiB; peak load (\d+)", log)
if t: out["monitor"]["throughput-2000"] = {"peak_mem_used_gib": int(t[1]), "mem_total_gib": int(t[2]), "baseline_gib": int(t[4]), "peak_load": int(t[5])}
out["throughput_failures"] = [ {"error": json.loads(l).get("error", "")[:120]} for l in open(d + "tput-2000.jsonl")
                               if json.loads(l).get("type") not in ("summary", "meta", "env") and json.loads(l).get("error")]
print(json.dumps(out, indent=1))

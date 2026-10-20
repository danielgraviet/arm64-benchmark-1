import json, sys, glob
d = sorted(glob.glob(f"/mnt/data/bench/run2k-{sys.argv[1]}-*"))[-1]
for l in open(d + "/tput-2000.jsonl"):
    r = json.loads(l)
    if r.get("type") not in ("summary", "meta", "env") and (r.get("exit_code") not in (0, None) or r.get("error")):
        print("tput failure:", {k: (str(v)[:120]) for k, v in r.items() if k in ("error", "exit_code", "latency_ms", "sandbox_id")})
for f in sorted(glob.glob(d + "/startup-idle-*.jsonl")):
    try:
        recs = [json.loads(l) for l in open(f)]
    except Exception:
        continue
    ok = [r for r in recs if r.get("type") == "sandbox" and r.get("status") == "ok"]
    if not ok: print(f.split("/")[-1], "no data"); continue
    slow = sorted(ok, key=lambda r: -r["create_s"])[:3]
    print(f.split("/")[-1], "slowest create_s:", [round(r["create_s"], 1) for r in slow], "probe_s:", [round(r.get("probe_s") or 0, 1) for r in slow])

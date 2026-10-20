"""9575F fixes OFF vs ON, from raw data (run on the 9575F as root)."""
import glob, json, re, sys

FB = sorted(glob.glob("/mnt/data/bench/fixes-bench-9575-2*"))[-1] + "/"
T7 = sorted(glob.glob("/mnt/data/bench/tput704-epyc9575-*"))[-1] + "/"


def q(v, p):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(p * len(v)))], 3) if v else None


def mpfleet(path):
    recs = [json.loads(l) for l in open(path)]
    s = recs[-1]
    c = [r["create_s"] for r in recs if r.get("type") == "sandbox" and r.get("status") == "ok"]
    return {"ok": s["ok"], "failed": s["failed"], "all_ready_s": round(s["ready_wall_s"], 3),
            "create_p50_s": q(c, .5), "create_p90_s": q(c, .9), "create_p95_s": q(c, .95), "create_p99_s": q(c, .99),
            "post_p50_s": round(s["post_p50_s"], 3)}


log = open(FB + "log").read()
ovf = {(m[0], m[1], m[2]): int(m[3]) for m in re.findall(r"STARTUP flags=(\w+) image=(\w+) rep=(\d) .*?overflows=(\d+)", log)}
startup = {}
for img in ("idle", "agent"):
    for f in ("off", "on"):
        runs = []
        for rep in (1, 2, 3):
            r = mpfleet(f"{FB}startup-{f}-{img}-{rep}.jsonl"); r["rep"] = rep; r["listen_overflows"] = ovf.get((f, img, str(rep)))
            runs.append(r)
        startup.setdefault(img, {})[f] = runs


def ladder(path):
    out = []
    for l in open(path):
        r = json.loads(l)
        if r.get("type") == "summary":
            out.append({"concurrency": r["concurrency"], "runs": r["runs"], "failures": r["failures"],
                        "jobs_per_s": r["throughput_per_sec"], "p50_s": round(r["p50_ms"] / 1000, 2),
                        "p99_s": round(r["p99_ms"] / 1000, 2)})
    return out


tput = {f: [x for x in ladder(f"{FB}tput-{f}.jsonl") if x["concurrency"] != 704] + ladder(f"{T7}tput704-{f}.jsonl")
        for f in ("off", "on")}
print(json.dumps({"startup_1000": startup, "throughput_ladder": tput,
                  "raw": {"startup_and_176_352": FB, "level_704_rerun_600s_read_timeout": T7},
                  "notes": ["level 704 from the rerun with RLP_HTTP_READ_TIMEOUT_S=600 (the first pass used 120 s, which "
                            "cut off healthy level-704 episodes: p50 83 s, p99 145 s on this host; 522/594 'failures' were "
                            "the client giving up, not sandboxes failing)"]}, indent=1))

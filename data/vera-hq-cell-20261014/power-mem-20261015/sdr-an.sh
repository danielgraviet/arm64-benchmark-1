for p in $(ps -eo pid,args | grep "PW Consumption" | grep -v grep | awk '{print $1}'); do kill $p; done
sleep 1; echo "sdr logger left: $(ps -eo args | grep 'PW Consumption' | grep -v grep | wc -l)"
S=$(ls -t /mnt/data/bench/ipmi-sdr-epyc9575-*.tsv | head -1); D=$(ls -dt /mnt/data/bench/power-epyc9575-* | head -1)
python3 - $S $D <<'PY'
import sys, json, statistics as st
rows = [l.split() for l in open(sys.argv[1]) if len(l.split()) == 3]
rows = [(float(t), float(s), float(d)) for t, s, d in rows]
D = sys.argv[2]
def samp(p):
    h = None; o = []
    for l in open(p):
        if l.startswith("#"): continue
        x = l.rstrip("\n").split("\t")
        if h is None: h = x; continue
        o.append(dict(zip(h, x)))
    return o
idle = samp(D + "/idle.samp"); lad = samp(D + "/ladder.samp")
S = [json.loads(l) for l in open(D + "/ladder.jsonl") if '"summary"' in l]
wins = {"idle": (float(idle[0]["t"]), float(idle[-1]["t"]))}
for k, s in enumerate(S):
    e = [float(r["t"]) for r in lad if int(r["nsum"]) >= k + 1]
    if e: wins[f"c{s['concurrency']}"] = (e[0] - s["exec_wall_s"], e[0])
print(f"{'window':7s} {'SDR PW Consumption':>19s} {'DCMI instantaneous':>19s} {'ratio':>6s} {'n':>4s}")
for w, (a, b) in wins.items():
    r = [x for x in rows if a <= x[0] <= b]
    if r: print(f"{w:7s} {st.mean(x[1] for x in r):19.0f} {st.mean(x[2] for x in r):19.0f} {st.mean(x[1] for x in r)/st.mean(x[2] for x in r):6.2f} {len(r):4d}")
PY

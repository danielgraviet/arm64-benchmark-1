import re, sys, collections
D = sys.argv[1]
ev = []
for l in open(D + "/wake.txt"):
    p = l.split(" ", 1)
    if p[0].isdigit(): ev.append((int(p[0]), p[1].strip()))
tid_ev = collections.defaultdict(list)
for t, s in ev:
    m = re.search(r"tid=(\d+)", s)
    if m and s.split()[0] in ("WFX", "WAKE"): tid_ev[m.group(1)].append(t)
vms = sorted((min(v), max(v), k) for k, v in tid_ev.items() if len(v) > 3)
print(f"vCPU threads (sandboxes) seen: {len(vms)}")
rows = []
for a, b, tid in vms:
    win = [(t, s) for t, s in ev if a - 5e6 <= t <= b]
    syn = next((t for t, s in win if s.startswith("TX2G len=74")), None)
    ack = next((t for t, s in win if syn and t > syn and s.startswith("RXFG len=60")), None) or \
          next((t for t, s in win if syn and t > syn and s.startswith("RXFG") and "len=28" not in s), None)
    rows.append((tid, a, syn, ack, win))
for tid, a, syn, ack, win in rows:
    d = (ack - syn) / 1e6 if syn and ack else None
    print(f"  vcpu tid={tid}  first SYN->first guest reply = {d if d is None else round(d,1)} ms")
slow = [r for r in rows if r[2] and r[3] and (r[3] - r[2]) > 100e6]
for tid, a, syn, ack, win in slow[:2]:
    print(f"\n=== SLOW vcpu tid={tid}: events from first SYN (t=0) to first guest reply ===")
    cnt = collections.Counter(); prev = None
    for t, s in win:
        if t < syn - 2e6 or t > ack + 1e6: continue
        k = s.split()[0] + (" " + s.split()[1] if s.startswith(("VGIC", "TIMER", "TX2G", "RXFG")) else "")
        if k == prev: cnt[k] += 1; continue
        print(f"  {(t - syn)/1e6:+9.3f} ms  {s[:100]}"); prev = k

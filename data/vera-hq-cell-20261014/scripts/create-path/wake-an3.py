import re, sys, collections
D = sys.argv[1]
ev = [(int(p[0]), p[1].strip()) for p in (l.split(" ", 1) for l in open(D + "/wake.txt")) if p[0].isdigit()]
tid_ev = collections.defaultdict(list)
for t, s in ev:
    m = re.search(r"tid=(\d+)", s)
    if m and s.split()[0] in ("WFX", "WAKE"): tid_ev[m.group(1)].append(t)
vms = sorted((min(v), max(v), k) for k, v in tid_ev.items() if len(v) > 3)
tw = [int(m.group(1)) for m in (re.search(r"toolbox_wait_ms=(\d+)", l) for l in open(D + "/runner.log")) if m]
# first vCPU activity per VM ~ resume; tap events in [resume-50ms, resume+1s]
print(f"{'tw_ms':>6} | ms after first vCPU event:  first ARP->guest | ARP reply | first SYN->guest | ARPs sent before SYN | gap ARP->reply")
for (a, b, tid), w in zip(vms, tw):
    win = [(t, s) for t, s in ev if a - 50e6 <= t <= a + 1.2e9]
    arp = [t for t, s in win if s.startswith("TX2G len=42")]
    rep = [t for t, s in win if s.startswith("RXFG len=28")]
    syn = next((t for t, s in win if s.startswith("TX2G len=74")), None)
    f = lambda t: f"{(t - a)/1e6:8.1f}" if t else "     n/a"
    n_arp_before = sum(1 for t in arp if syn and t < syn)
    gap = f"{(rep[0]-arp[0])/1e6:7.1f}" if arp and rep else "    n/a"
    print(f"{w:6d} | {f(arp[0] if arp else None)} | {f(rep[0] if rep else None)} | {f(syn)} | {n_arp_before:3d} | {gap}")

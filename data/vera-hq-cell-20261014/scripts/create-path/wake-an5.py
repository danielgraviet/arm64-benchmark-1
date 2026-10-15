import re, sys, collections
D = sys.argv[1]
ev = [(int(p[0]), p[1].strip()) for p in (l.split(" ", 1) for l in open(D + "/wake.txt")) if p[0].isdigit()]
tid_ev = collections.defaultdict(list)
for t, s in ev:
    m = re.search(r"tid=(\d+)", s)
    if m and s.split()[0] in ("WFX", "WAKE"): tid_ev[m.group(1)].append(t)
vms = sorted((min(v), max(v), k) for k, v in tid_ev.items() if len(v) > 3)
tw = [int(m.group(1)) for m in (re.search(r"toolbox_wait_ms=(\d+)", l) for l in open(D + "/runner.log")) if m]
for (a, b, tid), w in [(v, w) for v, w in zip(vms, tw) if w > 100][:3]:
    win = [(t, s) for t, s in ev if a - 60e6 <= t <= a + 700e6]
    arp = next(t for t, s in win if s.startswith("TX2G len=42"))
    rep = next(t for t, s in win if s.startswith("RXFG len=28") and t > arp)
    # packets host->guest between ARP and reply, and the vCPU wakes just before the reply
    tx = [(round((t-arp)/1e6,1), s.split()[1]) for t, s in win if arp < t < rep and s.startswith("TX2G")]
    wakes = [round((t-arp)/1e6,1) for t, s in win if arp < t < rep and s.startswith("WAKE")]
    irq36 = [round((t-arp)/1e6,1) for t, s in win if arp < t < rep and "irq=36" in s]
    print(f"slow VM tw={w}: reply at +{(rep-arp)/1e6:.1f} ms | host->guest packets in between: {tx} | irq36 at: {irq36} | vCPU wakes: {len(wakes)} (last 3: {wakes[-3:]})")
    for t, s in win:
        if rep - 3e6 <= t <= rep + 0.3e6: print(f"    {(t-arp)/1e6:+9.3f} ms  {s[:100]}")
    print()

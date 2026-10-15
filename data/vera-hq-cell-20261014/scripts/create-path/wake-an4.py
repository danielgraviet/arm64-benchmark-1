import re, sys, collections
D = sys.argv[1]; which = sys.argv[2] if len(sys.argv) > 2 else "slow"
ev = [(int(p[0]), p[1].strip()) for p in (l.split(" ", 1) for l in open(D + "/wake.txt")) if p[0].isdigit()]
tid_ev = collections.defaultdict(list)
for t, s in ev:
    m = re.search(r"tid=(\d+)", s)
    if m and s.split()[0] in ("WFX", "WAKE"): tid_ev[m.group(1)].append(t)
vms = sorted((min(v), max(v), k) for k, v in tid_ev.items() if len(v) > 3)
tw = [int(m.group(1)) for m in (re.search(r"toolbox_wait_ms=(\d+)", l) for l in open(D + "/runner.log")) if m]
picked = [(v, w) for v, w in zip(vms, tw) if (w > 100) == (which == "slow")][:1]
for (a, b, tid), w in picked:
    win = [(t, s) for t, s in ev if a - 60e6 <= t <= a + 700e6]
    arp = next(t for t, s in win if s.startswith("TX2G len=42"))
    rep = next(t for t, s in win if s.startswith("RXFG len=28") and t > arp)
    print(f"=== {which} VM (toolbox_wait={w} ms) vcpu tid={tid}: t=0 at the ARP request to the guest; reply at {(rep-arp)/1e6:.1f} ms ===")
    prev, run = None, 0
    for t, s in win:
        if t < arp - 8e6 or t > rep + 0.5e6: continue
        if "vcpu" in s or "tid=" in s or "TX2G" in s or "RXFG" in s or "SETIRQ" in s or "HRTIMER" in s or "UEXIT" in s:
            k = re.sub(r"[0-9a-f]{8,}|slept_ns=\d+|cpu=\d+", "", s)
            if k == prev: run += 1; continue
            if run: print(f"             (x{run} more)"); run = 0
            print(f"  {(t - arp)/1e6:+9.3f} ms  {s[:105]}"); prev = k

import re, sys, datetime as dt
D = sys.argv[1]
ev = []
for l in open(D + "/wake.txt"):
    p = l.split(" ", 1)
    if p[0].isdigit(): ev.append((int(p[0]), p[1].strip()))
# bpftrace nsecs = CLOCK_MONOTONIC; runner logs are wall clock -> align via offset of first TX2G vs first boot log is unsafe;
# instead segment by TX2G bursts: a probe sequence = TX2G events separated from the previous by > 300 ms.
tx = [t for t, s in ev if s.startswith("TX2G")]
starts = [tx[0]] + [b for a, b in zip(tx, tx[1:]) if b - a > 300e6]
tw = [int(m.group(1)) for m in (re.search(r"toolbox_wait_ms=(\d+)", l) for l in open(D + "/runner.log")) if m]
print(f"probe sequences found={len(starts)}  runner toolbox_wait_ms in order={tw}")
def show(i, n=40):
    t0 = starts[i]; win = [(t, s) for t, s in ev if t0 - 150e6 <= t <= t0 + 700e6]
    print(f"\n=== sequence {i} (runner toolbox_wait={tw[i] if i < len(tw) else '?'} ms), t=0 at first packet to guest ===")
    last = None; k = 0
    for t, s in win:
        key = s.split()[0]
        if key in ("WFX",) and last == "WFX": continue  # collapse idle loops
        print(f"  {(t - t0)/1e6:+9.3f} ms  {s[:110]}"); last = key; k += 1
        if k >= n: break
slow = [i for i, w in enumerate(tw) if w > 100][:2]; fast = [i for i, w in enumerate(tw) if w < 10][:1]
for i in slow[:1] + fast: show(i)

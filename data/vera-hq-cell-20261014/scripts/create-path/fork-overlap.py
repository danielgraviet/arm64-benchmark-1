import sys
iv = sorted((int(a), int(b)) for t, a, b in (l.split() for l in open(sys.argv[1]) if l.startswith("F ")))
if not iv: sys.exit("no forks")
t0, t1 = iv[0][0], max(b for _, b in iv)
ev = sorted([(a, 1) for a, _ in iv] + [(b, -1) for _, b in iv])
cur = peak = 0; busy = 0; last = None; over1 = 0
for t, d in ev:
    if last is not None and cur > 0: busy += t - last
    if last is not None and cur > 1: over1 += t - last
    cur += d; peak = max(peak, cur); last = t
durs = sorted(b - a for a, b in iv)
q = lambda p: durs[min(len(durs) - 1, int(p * len(durs)))] / 1e3
print(f"forks={len(iv)} span={(t1-t0)/1e9:.2f}s  fork-syscall busy={busy/1e9:.2f}s ({100*busy/(t1-t0):.0f}% of span)  "
      f"time with >1 fork in flight={over1/1e9:.3f}s  peak concurrent forks={peak}")
print(f"fork syscall duration us: p50={q(.5):.0f} p90={q(.9):.0f} p99={q(.99):.0f} max={durs[-1]/1e3:.0f}  sum={sum(durs)/1e9:.2f}s")
# busiest 1-second windows
b = {}
for a, e in iv: b.setdefault(int((a - t0) / 1e9), 0); b[int((a - t0) / 1e9)] += (e - a)
print("fork-busy fraction per second of the burst:", " ".join(f"{100*v/1e9:.0f}%" for k, v in sorted(b.items())[:12]))

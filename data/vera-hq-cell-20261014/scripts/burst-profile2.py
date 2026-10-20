import re,sys,datetime as dt
def ts(l): return dt.datetime.fromisoformat(re.search(r'time=(\S+)Z',l).group(1)).timestamp()
def q(xs,p): xs=sorted(xs); return xs[min(len(xs)-1,int(p*len(xs)))]
for J in sys.argv[1:]:
    tot={}; emit={}; fcs={}
    for l in open(J,errors="replace"):
        m=re.search(r'vm_id=(\S+)',l)
        if not m: continue
        v=m.group(1)
        if 'msg=boot-phases ' in l:
            tot[v]=int(re.search(r'total_ms=(\d+)',l).group(1)); fcs[v]=int(re.search(r'fc_start_ms=(\d+)',l).group(1))
        elif 'msg=running-emit' in l: emit[v]=ts(l)
    vs=[v for v in emit if v in tot]; t0=min(emit[v]-tot[v]/1000 for v in vs)
    start=[emit[v]-tot[v]/1000-t0 for v in vs]
    print(f"== {J.split('/bench/')[-1]}")
    print(f"  clone START since first: p50={q(start,.5):.2f}s p95={q(start,.95):.2f}s max={max(start):.2f}s")
    # in-flight clones over time (concurrency actually achieved)
    ev=sorted([(s,1) for s in start]+[(s+tot[v]/1000,-1) for s,v in zip(start,vs)])
    cur=peak=0
    for _,d in ev: cur+=d; peak=max(peak,cur)
    print(f"  peak concurrent clones in flight={peak}")
    b=[0]*int(max(start)+1)
    for s in start: b[int(s)]+=1
    print("  clone starts per second:", " ".join(map(str,b[:25])))
    # fc_start by start-second
    bb={}
    for s,v in zip(start,vs): bb.setdefault(int(s),[]).append(fcs[v])
    print("  fc_start p50 by start-second:", " ".join(f"{k}:{q(x,.5)}" for k,x in sorted(bb.items())[:20]))

import re,sys,datetime as dt,statistics as st
def ts(l): return dt.datetime.fromisoformat(re.search(r'time=(\S+)Z',l).group(1)).timestamp()
for J in sys.argv[1:]:
    pick={}; ph={}; emit={}
    for l in open(J,errors="replace"):
        m=re.search(r'vm_id=(\S+)',l)
        if not m: continue
        v=m.group(1)
        if 'msg="boot-phases create"' in l: pick.setdefault(v,ts(l))
        elif 'msg=boot-phases ' in l: ph[v]={k:int(x) for k,x in re.findall(r'(\w+_ms)=(\d+)',l)}
        elif 'msg=running-emit' in l: emit[v]=ts(l)
    t0=min(pick.values()) if pick else min(emit.values())
    def q(xs,p): xs=sorted(xs); return xs[min(len(xs)-1,int(p*len(xs)))] if xs else float('nan')
    print(f"== {J.split('/bench/')[-1]}  vms={len(ph)} picked={len(pick)} emitted={len(emit)}")
    E=[emit[v]-t0 for v in emit]
    print(f"  running-emit since first pickup: p50={q(E,.5):.2f}s p95={q(E,.95):.2f}s max={max(E):.2f}s")
    P=[pick[v]-t0 for v in pick]
    if P: print(f"  'boot-phases create' log since first: p50={q(P,.5):.2f}s p95={q(P,.95):.2f}s max={max(P):.2f}s")
    for k in ["total_ms","clone_ms","netns_get_ms","scratch_cp_ms","fc_start_ms","load_ms","toolbox_wait_ms"]:
        xs=[d[k] for d in ph.values() if k in d]
        if xs: print(f"  {k:16s} p50={q(xs,.5):6d} p95={q(xs,.95):6d} max={max(xs):6d}  sum={sum(xs)/1000:7.1f}s")
    # emit-rate in 1 s buckets
    b=[0]*int(max(E)+1)
    for e in E: b[int(e)]+=1
    print("  emits per second:", " ".join(map(str,b[:30])))

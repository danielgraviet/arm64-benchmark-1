import sys,json
# sampler cols: t, power_w, ghz, fc, n_summaries
rows=[]
for l in open(sys.argv[1]):
    p=l.rstrip("\n").split("\t")
    if not p or not p[0][:1].isdigit(): continue
    try: rows.append((float(p[0]), p[1], float(p[2]) if p[2] else None, int(p[3]), int(p[4])))
    except Exception: pass
print(f"samples={len(rows)}")
if not rows: sys.exit()
def mean(x): return sum(x)/len(x) if x else None
# light load = while the first level (n_summaries==0) runs and fc>0 ; packed = last level, fc>1500
light=[g for t,p,g,fc,n in rows if n==0 and fc>0 and g]
packed=[g for t,p,g,fc,n in rows if fc>=1500 and g]
idle=[g for t,p,g,fc,n in rows if fc==0 and g]
pw_packed=[float(p) for t,p,g,fc,n in rows if fc>=1500 and p not in ("","nan")]
pw_light=[float(p) for t,p,g,fc,n in rows if n==0 and fc>0 and p not in ("","nan")]
for name,v in (("idle",idle),("light (c=44)",light),("packed (fc>=1500)",packed)):
    print(f"  GHz {name:<20} n={len(v):4} mean={mean(v):.3f}" if v else f"  GHz {name:<20} no data")
if light and packed:
    print(f"  clock drop packed vs light: {(mean(packed)/mean(light)-1)*100:+.1f}%")
if pw_packed: print(f"  power packed mean={mean(pw_packed):.0f} W   light mean={mean(pw_light):.0f} W" if pw_light else f"  power packed mean={mean(pw_packed):.0f} W")
print(f"  peak fc={max(fc for _,_,_,fc,_ in rows)}")

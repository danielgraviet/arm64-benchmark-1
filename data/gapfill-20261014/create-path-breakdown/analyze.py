import json,re,glob,sys,statistics,datetime,collections
def ts(s): return datetime.datetime.strptime(s.rstrip("Z"),"%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp()
def load_j(h):
    runs={}; cur=None
    for l in open(f"j-{h}.txt"):
        if l.startswith("### "): cur=l[4:].strip(); runs[cur]={}; continue
        m=re.search(r'time=(\S+) .*?msg=("boot-phases create"|boot-phases|running-emit) vm_id=(\S+)(.*)',l)
        if not m: continue
        t,kind,vid,rest=m.groups(); d=runs[cur].setdefault(vid,{})
        kv=dict(re.findall(r'(\w+)=(\S+)',rest))
        if kind=='"boot-phases create"': d["t_handler"]=ts(t); d["deliver_ms"]=int(kv.get("deliver_ms",0)); d["ndeliv"]=int(kv.get("num_delivered",1))
        elif kind=="boot-phases": d["t_cloned"]=ts(t); d.update({k:int(v) for k,v in kv.items() if k.endswith("_ms")}); d["template"]=kv.get("template")
        else: d["t_emit"]=int(kv["epoch_ms"])/1000
    return runs
import uuid
A58="123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
def vmid(s):
    if not s: return s
    if len(s)==36 and s.count("-")==4: return s
    b=s.split("-")[0]; n=0
    for ch in b: n=n*58+A58.index(ch)
    return str(uuid.UUID(bytes=n.to_bytes(16,"big")))
def q(a,p):
    a=sorted(a); return a[min(len(a)-1,int(p*len(a)))] if a else float("nan")
STEPS=["S1 client→API: POST answered","S2 request sent → runner starts (API + queue)","S3 runner admission/image (pre-clone)",
 "S4a netns from pool","S4b scratch + init-disk copy","S4c Firecracker spawn + API socket","S4d snapshot load + resume",
 "S4e guest toolbox port accepts","S4f other (cgroup, register, entrypoint trigger)","S4 = runner clone total",
 "S5 running event → client sees running","S6 first exec (echo ready)","TOTAL request → first exec done"]
def per_run(f,J):
    rows=[json.loads(l) for l in open(f) if l.strip()]
    sb=[r for r in rows if r.get("type")=="sandbox" and r.get("status")=="ok"]
    V={k:[] for k in STEPS}; miss=0
    for r in sb:
        d=J.get(vmid(r.get("sandbox_id")))
        if not d or "t_handler" not in d or "t_cloned" not in d or "t_emit" not in d: miss+=1; continue
        t0=r["t_start"]; tpost=t0+r["post_s"]; tseen=t0+r["create_s"]
        parts=[d.get("netns_get_ms",0),d.get("scratch_cp_ms",0),d.get("fc_start_ms",0),d.get("load_ms",0),d.get("toolbox_wait_ms",0)]
        vals=[r["post_s"]*1e3,(d["t_handler"]-t0)*1e3,(d["t_cloned"]-d["t_handler"])*1e3-d["total_ms"]]+parts+[d["clone_ms"]-sum(parts),d["total_ms"],
              (tseen-d["t_emit"])*1e3,r["probe_s"]*1e3,(r["create_s"]+r["probe_s"])*1e3]
        for k,v in zip(STEPS,vals): V[k].append(v)
    return V,len(sb),miss
if __name__=="__main__":
    out={}
    for h in ["vera","e9575","g5","turin"]:
        J=load_j(h)
        for tag,Jr in J.items():
            f=tag.replace("__","/")
            V,n,miss=per_run(f,Jr)
            out[f"{h}|{f}"]={"n":n,"miss":miss,"steps":{k:[round(q(v,.5),1),round(q(v,.9),1)] for k,v in V.items()},"raw":V}
            print(h,f,"n",n,"miss",miss,"total p50",round(q(V[STEPS[-1]],.5)),"S2",round(q(V[STEPS[1]],.5)))
    json.dump(out,open("steps-out.json","w"))

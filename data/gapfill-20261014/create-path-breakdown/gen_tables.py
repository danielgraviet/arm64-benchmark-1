import json
A=json.load(open("agg.json")); W=json.load(open("agg-warm.json"))
NAMES={"vera":"HQ Vera","e9575":"EPYC 9575F","turin":"Turin","g5":"Graviton5"}
LABEL={
 "S1 client→API: POST answered":"A · API accepts the create (POST answered)#super[†]",
 "S2 request sent → runner starts (API + queue)":"B · request sent → runner starts the job (API + JetStream queue)",
 "S3 runner admission/image (pre-clone)":"C · runner admission, image + template lookup",
 "S4a netns from pool":"D1 · network namespace from the pool",
 "S4b scratch + init-disk copy":"D2 · scratch copy + 16 MiB init disk (fsync)",
 "S4c Firecracker spawn + API socket":"D3 · Firecracker spawn + API socket",
 "S4d snapshot load + resume":"D4 · snapshot load + resume",
 "S4e guest toolbox port accepts":"D5 · guest toolbox port accepts",
 "S4f other (cgroup, register, entrypoint trigger)":"D6 · cgroup create/join, register, entrypoint trigger",
 "S4 = runner clone total":"*D · runner clone total*",
 "S5 running event → client sees running":"E · running event → client sees it (NATS → API → SDK poll)",
 "S6 first exec (echo ready)":"F · first command through the proxy (`echo ready`)",
 "TOTAL request → first exec done":"*Total: request → first command done*"}
def cell(v,best=False):
    s=f"{v[0]:,} / {v[1]:,}"
    return f"[#w[{s}]]" if best else f"[{s}]"
def table(cols, data, name):
    steps=list(LABEL)
    out=[f"#let {name} = table(columns: (2.5fr,{','.join(['1fr']*len(cols))}),"]
    out.append("  [Step (ms, p50 / p90)], "+", ".join(f"[{h}]" for h,_ in cols)+",")
    for s in steps:
        vals=[data[k]["steps"][s] for _,k in cols]
        # highlight the largest runner sub-phase per column? keep plain; bold totals
        row=[f"[{LABEL[s]}]"]
        for v in vals: row.append(cell(v))
        out.append("  "+", ".join(row)+",")
    out.append("  [samples], "+", ".join(f"[{data[k]['n']:,}]" for _,k in cols)+",")
    out.append(")")
    return "\n".join(out)
T=[]
def c(h,n,img,arm): return (f"{NAMES[h]} {arm}", f"{h}|{n}|{img}|{arm}")
T.append(table([c("vera","1k","idle","off"),c("vera","1k","idle","on"),c("e9575","1k","idle","off"),c("e9575","1k","idle","on"),c("g5","1k","idle","off"),c("g5","1k","idle","on"),c("turin","1k","idle","on")],A,"t1kidle"))
T.append(table([c("vera","1k","agent","off"),c("vera","1k","agent","on"),c("e9575","1k","agent","off"),c("e9575","1k","agent","on"),c("g5","1k","agent","off"),c("g5","1k","agent","on"),c("turin","1k","agent","on")],A,"t1kagent"))
T.append(table([c("vera","2k","idle","on"),c("e9575","2k","idle","on"),c("turin","2k","idle","on"),c("vera","2k","agent","on"),c("e9575","2k","agent","on"),c("turin","2k","agent","on")],A,"t2k"))
cw=[(f"{NAMES[h]} {a}",f"{h}|{a}") for h in ["vera","e9575","g5"] for a in ["off","on"]]
T.append(table(cw,W,"twarm"))
open("tables.typ","w").write("#let w(x) = text(weight: \"bold\", fill: rgb(\"#1a6b2f\"), x)\n"+"\n\n".join(T)+"\n")
print("ok")

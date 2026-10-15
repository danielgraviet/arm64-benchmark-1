import re,sys,subprocess,collections
# usage: phases.py LABEL SINCE UNTIL [LABEL SINCE UNTIL ...]   (UTC, today)
a=sys.argv[1:]
keys=["total_ms","clone_ms","scratch_cp_ms","fc_start_ms","load_ms","toolbox_wait_ms","netns_get_ms","bind_ms","adopt_ms"]
q=lambda v,p: sorted(v)[min(len(v)-1,int(p*len(v)))] if v else -1
for i in range(0,len(a),3):
    lab,s,u=a[i:i+3]
    out=subprocess.run(["journalctl","-u","rlp-runner","--no-pager","-o","cat","--since",s,"--until",u],capture_output=True,text=True).stdout
    d=collections.defaultdict(list); n=0; tmpl=collections.Counter()
    for l in out.splitlines():
        if "msg=boot-phases" not in l: continue
        kv=dict(re.findall(r'(\w+)=([\w.:-]+)',l)); n+=1; tmpl[kv.get("template")]+=1
        for k in keys:
            if k in kv:
                try: d[k].append(int(kv[k]))
                except: pass
    print(f"{lab:10} n={n} template={dict(tmpl)}")
    print("   "+"  ".join(f"{k[:-3]}={q(d[k],.5)}/{q(d[k],.95)}/{max(d[k]) if d[k] else -1}" for k in keys if d[k]))

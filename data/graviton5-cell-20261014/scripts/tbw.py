import re,sys,subprocess
# count toolbox_wait > 1000 ms per window
for lab,s,u in [a.split("|") for a in sys.argv[1:]]:
    out=subprocess.run(["journalctl","-u","rlp-runner","--no-pager","-o","cat","--since",s,"--until",u],capture_output=True,text=True).stdout
    tw=[int(m.group(1)) for m in re.finditer(r"msg=boot-phases .*toolbox_wait_ms=(\d+)",out)]
    tw.sort()
    print(f"{lab:14} n={len(tw)} p50={tw[len(tw)//2] if tw else -1} p99={tw[int(.99*len(tw))] if tw else -1} >1s={sum(1 for x in tw if x>1000)} >5s={sum(1 for x in tw if x>5000)} max={tw[-1] if tw else -1}")

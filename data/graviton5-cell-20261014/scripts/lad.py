import json,sys,glob
for f in sorted(glob.glob(sys.argv[1])):
    print("==",f)
    for l in open(f):
        try: r=json.loads(l)
        except: continue
        if r.get("type")=="summary":
            print(f"c={r['concurrency']:5} runs={r['runs']:6} fail={r['failures']:4} tput={r['throughput_per_sec']:7}/s p50_dur={r['p50_duration_ms']/1000:6.2f}s p99={r['p99_ms']/1000:6.1f}s create_wall={r.get('create_wall_s')}")

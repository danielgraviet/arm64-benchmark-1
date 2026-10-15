import json,sys
rows=[]
for l in open(sys.argv[1]):
    if '"summary"' not in l: continue
    s=json.loads(l)
    if s.get("type")=="summary" and "concurrency" in s: rows.append(s)
print(f"{'conc':>6} {'runs':>6} {'fail':>5} {'tput/s':>8} {'p50_dur_s':>10} {'exec_wall_s':>11} {'cksum_ok':>8}")
for s in rows:
    print(f"{s['concurrency']:>6} {s.get('runs',0):>6} {s.get('failures',0):>5} {s['throughput_per_sec']:>8.2f} "
          f"{s['p50_duration_ms']/1000:>10.2f} {s.get('exec_wall_s',0):>11.1f} {str(s.get('checksum_ok')):>8}")
tp=[(s['concurrency'],s['throughput_per_sec']) for s in rows if s['concurrency']>=352]
if tp: print(f"\nplateau (>=352): min {min(t for _,t in tp):.2f}  max {max(t for _,t in tp):.2f}  mean {sum(t for _,t in tp)/len(tp):.2f} jobs/s")

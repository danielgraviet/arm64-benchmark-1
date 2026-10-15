import json,glob,sys,statistics as st
print("run            send_spread  host_overlap  guest_clock_lag  memtest_duration")
for f in sorted(glob.glob(sys.argv[1]+"/c*-r*.jsonl"), key=lambda p:(int(p.split("/c")[-1].split("-")[0]),p)):
    r=[json.loads(l) for l in open(f)]; ok=[x for x in r if x.get("status")=="ok"]
    s=[x["t_exec_send"] for x in ok]; d=[x["t_exec_done"] for x in ok]; gs=[x["t_start"] for x in ok]
    dur=[x["duration_ms"]/1000 for x in ok]; name=f.split("/")[-1]
    print(f"{name:14} {max(s)-min(s):8.3f} s  {min(d)-max(s):8.2f} s  {st.median(s)-st.median(gs):10.0f} s     {min(dur):.2f}-{max(dur):.2f} s")

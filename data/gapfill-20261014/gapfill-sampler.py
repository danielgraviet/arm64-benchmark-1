#!/usr/bin/env python3
# gapfill sampler: power (Vera AP hwmon / x86 RAPL pkg), mean clock, firecracker count, ladder summaries seen
import sys,time,glob,os
out,watch=sys.argv[1],sys.argv[2]
ap=[h for h in glob.glob("/sys/class/hwmon/hwmon*") if "AP Power in uW socket" in (open(h+"/power1_oem_info").read() if os.path.exists(h+"/power1_oem_info") else "")]
rapl=[z for z in glob.glob("/sys/class/powercap/intel-rapl:[0-9]") if os.path.exists(z+"/energy_uj")]
freqs=sorted(glob.glob("/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq"))[::8]
def rd(p):
    try: return int(open(p).read())
    except Exception: return None
def nsum():
    if not watch or not os.path.exists(watch): return 0
    return sum(1 for l in open(watch) if '"type": "summary"' in l or '"type":"summary"' in l)
def fc(): return sum(1 for p in os.listdir("/proc") if p.isdigit() and (open(f"/proc/{p}/comm").read().strip()=="firecracker" if os.path.exists(f"/proc/{p}/comm") else False))
e0=[rd(z+"/energy_uj") for z in rapl]; t0=time.time()
with open(out,"w") as fh:
    fh.write(f"# power_src={'ap_hwmon' if ap else ('rapl_pkg' if rapl else 'none')} n={len(ap) or len(rapl)}\nt\tpower_w\tghz\tfc\tnsum\tmemavail_gib\n")
    while True:
        time.sleep(2); t=time.time()
        if ap: pw=sum((rd(h+"/power1_average") or 0) for h in ap)/1e6
        elif rapl:
            e=[rd(z+"/energy_uj") for z in rapl]
            d=[((b-a) if b>=a else b) for a,b in zip(e0,e) if a is not None and b is not None]
            pw=sum(d)/1e6/(t-t0) if d and len(d)==len(rapl) else float("nan"); e0=e
        else: pw=float("nan")
        fs=[x for x in (rd(f) for f in freqs) if x]; g=sum(fs)/len(fs)/1e6 if fs else float("nan")
        ma=next((int(l.split()[1])//1048576 for l in open("/proc/meminfo") if l.startswith("MemAvailable")),-1)
        fh.write(f"{t:.1f}\t{pw:.1f}\t{g:.2f}\t{fc()}\t{nsum()}\t{ma}\n"); fh.flush(); t0=t

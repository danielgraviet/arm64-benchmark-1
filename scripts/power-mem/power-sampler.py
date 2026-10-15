#!/usr/bin/env python3
"""power-sampler.py OUT.tsv [LADDER.jsonl] — every 2 s: every power domain the host exposes, busy-core clock, fc count.

Domains (whatever exists; columns are fixed per host and listed in the '# domains' header line):
  Vera (ACPI power meters, hwmon power1_average in uW): 'Total Power', 'AP Power', 'CPU Rail Power', 'SOC Rail Power',
       'DRAM Power' per socket  -> vera_total_s0, vera_ap_s0, vera_cpu_s0, vera_soc_s0, vera_dram_s0, ... _s1
  x86 (RAPL, energy_uj deltas): package per socket -> rapl_pkg_s0, rapl_pkg_s1 (no DRAM domain on AMD)
  BMC wall power (ipmitool dcmi power reading, every 10 s, if it works) -> wall_w
Clock: busy-weighted mean scaling_cur_freq over CPUs that were >=90 % busy in the interval (busy_ghz), plus the
  number of such CPUs (busy_cpus). Same method on every host, so light-vs-packed clock drops are comparable.
  Graviton5 has no cpufreq: busy_ghz = nan (fixed 3.3 GHz).
Must run as root (energy_uj and some hwmon files are root-only).
"""
import glob, os, re, subprocess, sys, time

out = sys.argv[1]; watch = sys.argv[2] if len(sys.argv) > 2 else ""
def rd(p):
    try:
        with open(p) as f: return f.read().strip()
    except Exception: return None
def rint(p):
    v = rd(p)
    try: return int(v)
    except Exception: return None

# --- discover domains
cols = []  # (name, kind, path)
MAP = {"Total Power in uW": "vera_total", "AP Power in uW": "vera_ap", "CPU Rail Power in uW": "vera_cpu",
       "SOC Rail Power in uW": "vera_soc", "DRAM Power in uW": "vera_dram"}
for h in sorted(glob.glob("/sys/class/hwmon/hwmon*"), key=lambda x: int(re.sub(r"\D", "", x) or 0)):
    info = rd(h + "/power1_oem_info") or ""
    m = re.match(r"(.*) socket (\d+)$", info)
    if m and m.group(1) in MAP and os.path.exists(h + "/power1_average"):
        cols.append((f"{MAP[m.group(1)]}_s{m.group(2)}", "uw", h + "/power1_average"))
for z in sorted(glob.glob("/sys/class/powercap/intel-rapl:[0-9]")):
    name = rd(z + "/name") or ""
    if name.startswith("package") and os.path.exists(z + "/energy_uj"):
        cols.append((f"rapl_pkg_s{z.rsplit(':',1)[1]}", "uj", z + "/energy_uj"))
cols.sort()
def wall():
    try:
        o = subprocess.run(["ipmitool", "dcmi", "power", "reading"], capture_output=True, text=True, timeout=8).stdout
        m = re.search(r"Instantaneous power reading:\s+(\d+)\s+Watts", o)
        return float(m.group(1)) if m else None
    except Exception: return None
have_wall = wall() is not None
freqf = {int(re.search(r"cpu(\d+)/", p).group(1)): p for p in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq")}
def cpustat():
    d = {}
    for l in open("/proc/stat"):
        if l.startswith("cpu") and l[3].isdigit():
            f = l.split(); v = list(map(int, f[1:9])); d[int(f[0][3:])] = (sum(v) - v[3] - v[4], sum(v))
    return d
def nsum():
    if not watch or not os.path.exists(watch): return 0
    return sum(1 for l in open(watch) if '"type": "summary"' in l or '"type":"summary"' in l)
def fc():
    n = 0
    for p in os.listdir("/proc"):
        if p.isdigit():
            c = rd(f"/proc/{p}/comm")
            if c == "firecracker": n += 1
    return n

with open(out, "w") as fh:
    fh.write(f"# domains={','.join(c[0] for c in cols)} wall={'ipmi' if have_wall else 'none'} cpufreq={'yes' if freqf else 'no'} host={os.uname().nodename}\n")
    fh.write("\t".join(["t"] + [c[0] for c in cols] + ["wall_w", "busy_ghz", "busy_cpus", "fc", "nsum", "memavail_gib"]) + "\n")
    prev_e = {c[0]: rint(c[2]) for c in cols if c[1] == "uj"}; prev_s = cpustat(); t0 = time.time(); last_wall = None; k = 0
    while True:
        time.sleep(2); t = time.time(); dt = t - t0; t0 = t; k += 1
        vals = []
        for name, kind, path in cols:
            v = rint(path)
            if kind == "uw": vals.append(f"{v/1e6:.1f}" if v is not None else "nan")
            else:
                p = prev_e.get(name); prev_e[name] = v
                vals.append(f"{(v - p if v >= p else v)/1e6/dt:.1f}" if (v is not None and p is not None) else "nan")
        if have_wall and k % 5 == 1: last_wall = wall()
        s = cpustat(); busy = []
        for c, (b, tot) in s.items():
            pb, pt = prev_s.get(c, (b, tot))
            if tot - pt > 0 and (b - pb) / (tot - pt) >= 0.9: busy.append(c)
        prev_s = s
        fs = [rint(freqf[c]) for c in busy if c in freqf]; fs = [x for x in fs if x]
        g = f"{sum(fs)/len(fs)/1e6:.3f}" if fs else "nan"
        ma = next((int(l.split()[1]) // 1048576 for l in open("/proc/meminfo") if l.startswith("MemAvailable")), -1)
        fh.write("\t".join([f"{t:.1f}"] + vals + [f"{last_wall:.0f}" if last_wall else "nan", g, str(len(busy)), str(fc()), str(nsum()), str(ma)]) + "\n")
        fh.flush()

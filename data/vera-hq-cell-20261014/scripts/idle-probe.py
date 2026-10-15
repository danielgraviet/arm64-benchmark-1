"""Idle-guest CPU probe: N sandboxes idle; compare guest-reported idle% (guest /proc/stat) with host CPU of each FC's threads."""
import os, sys, time, subprocess, json
from pathlib import Path
ROOT = Path.home() / "arm64-benchmark-1"; sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from dotenv import load_dotenv; load_dotenv(ROOT / ".env")
import rlp_light_create_fleet as F
from rlp import Daytona
from harness.regions import resolve_rlp_client_config
N = int(sys.argv[1]) if len(sys.argv) > 1 else 1
cfg = resolve_rlp_client_config("vera")
client = Daytona(cfg)
sbs = [client.create(F.build_params(target="vera", image="dtgraviet/vera-agent-benchmark:v3", cpu=0.025, memory=0.0625, disk=1.0, idx=i), timeout=120) for i in range(N)]
time.sleep(3)
def host_threads():
    out = subprocess.run(["bash", "-c", "for p in $(pgrep -x firecracker); do for t in /proc/$p/task/*; do echo \"$p $(cat $t/comm) $(awk '{print $14+$15}' $t/stat)\"; done; done"], capture_output=True, text=True).stdout
    d = {}
    for l in out.splitlines():
        p, *name, ticks = l.split(); d[(p, " ".join(name))] = int(ticks)
    return d
h0 = host_threads()
PS = "for p in /proc/[0-9]*; do echo \"$(basename $p) $(cat $p/comm 2>/dev/null) $(awk '{print $14+$15}' $p/stat 2>/dev/null)\"; done"
g = sbs[0].process.exec("head -1 /proc/stat; " + PS + " > /tmp/a; sleep 10; head -1 /proc/stat; " + PS + " > /tmp/b; cat /proc/loadavg; echo ===; cat /tmp/a; echo ===; cat /tmp/b; echo ===; cat /proc/cmdline; tr '\\0' ' ' < /proc/1/cmdline; echo", timeout=40).result
h1 = host_threads()
hz = os.sysconf("SC_CLK_TCK")
agg = {}
for k, v in h1.items():
    agg.setdefault(k[1], 0.0); agg[k[1]] += (v - h0.get(k, v)) / hz / 10.0
print(json.dumps({"sandboxes": N, "host_cpu_per_thread_kind_cores": {k: round(v, 2) for k, v in sorted(agg.items())}}))
parts = g.split("===\n"); head = parts[0].splitlines()
pa = {l.split()[0]: (l.split()[1:-1], int(l.split()[-1])) for l in parts[1].splitlines() if len(l.split()) >= 3}
pb = {l.split()[0]: (l.split()[1:-1], int(l.split()[-1])) for l in parts[2].splitlines() if len(l.split()) >= 3}
top = sorted(((pb[k][1] - pa.get(k, (None, pb[k][1]))[1], k, " ".join(pb[k][0])) for k in pb), reverse=True)[:6]
print("guest0 per-process CPU ticks over 10 s (100 ticks = 1 core-s if guest HZ=100):", top)
print("guest cmdline / pid1:", parts[3].strip()[:400])
lines = [l for l in head if l.startswith("cpu ")] + [l for l in parts[0].splitlines() if l and l[0].isdigit()]
lines = head[:1] + [l for l in parts[0].splitlines()[1:] if l.startswith("cpu ")]
lines = [l for l in g.splitlines() if l.startswith("cpu ")] + [l for l in head if not l.startswith("cpu ")]
a = list(map(int, lines[0].split()[1:9])); b = list(map(int, lines[1].split()[1:9]))
d = [y - x for x, y in zip(a, b)]; tot = sum(d)
print(f"guest0 /proc/stat over 10 s: idle={100*(d[3]+d[4])/tot:.1f}% user={100*d[0]/tot:.1f}% sys={100*d[2]/tot:.1f}%")

for s in sbs: client.delete(s)

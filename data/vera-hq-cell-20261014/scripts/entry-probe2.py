"""Host CPU of one fresh sandbox's FC threads, 0.5 s resolution from create; plus guest process list at the end."""
import os, sys, time, subprocess, json
from pathlib import Path
ROOT = Path.home() / "arm64-benchmark-1"; sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from dotenv import load_dotenv; load_dotenv(ROOT / ".env")
import rlp_light_create_fleet as F
from rlp import Daytona
from harness.regions import resolve_rlp_client_config
client = Daytona(resolve_rlp_client_config("vera"))
hz = os.sysconf("SC_CLK_TCK")
def fc_ticks():
    out = subprocess.run(["bash", "-c", "for p in $(pgrep -x firecracker); do for t in /proc/$p/task/*; do awk '{print $14+$15}' $t/stat; done; done"], capture_output=True, text=True).stdout
    return sum(int(x) for x in out.split())
t0 = time.time()
sb = client.create(F.build_params(target="vera", image=os.environ.get("IMG","alpine:3.20"), cpu=0.025, memory=0.0625, disk=1.0, idx=0), timeout=120)
print(f"created+running after {time.time()-t0:.2f}s")
prev = fc_ticks(); tp = time.time(); series = []
for i in range(60):
    time.sleep(0.5); c = fc_ticks(); now = time.time()
    series.append(round((c - prev) / hz / (now - tp), 2)); prev, tp = c, now
print("host cores used by the sandbox's FC, every 0.5 s for 30 s:", series)
r = sb.process.exec("for p in /proc/[0-9]*; do echo \"$(basename $p) $(cat $p/comm) $(awk '{print $14+$15}' $p/stat)\"; done | sort -k3 -n | tail -5; cat /proc/uptime", timeout=30).result
print("guest processes (pid comm ticks), top 5 + uptime:\n" + r)
client.delete(sb)

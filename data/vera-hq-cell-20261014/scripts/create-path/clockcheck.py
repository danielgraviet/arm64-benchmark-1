import os, sys, time
sys.path.insert(0, os.path.expanduser("~/steps"))
import stepclient as S
k = S.key(); api, tb = S.clients(k, 8)
for i in range(3):
    p = api.post("/vms", json=S.body("alpine:3.20", i)).json(); vid, tok = p["vm_id"], p["access_token"]
    api.get(f"/vms/{vid}", params={"wait": "running", "timeout_ms": 30000}, timeout=40)
    r = tb.post(f"/{vid}/process/execute", json={"command": "cat /proc/uptime; date +%s.%N", "timeout": 10},
                headers={"Authorization": f"Bearer {tok}"}).json().get("result", "").split()
    print(f"clone {i}: host time={time.time():.3f}  guest uptime(monotonic)={r[0]} s  guest realtime={r[2]}")
    api.delete(f"/vms/{vid}"); time.sleep(2)

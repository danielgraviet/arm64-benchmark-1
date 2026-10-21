#!/usr/bin/env python3
"""Sandbox-level network test on the atl1node853 cell (run on 853 from the harness dir, as root).

Through the real guest path: virtio-net -> tap -> netns 1:1 NAT -> veth -> host masquerade -> bond0.
iperf3 servers must already listen on node 864 (10.46.90.71) ports 5201-5264.
  1. single sandbox at 1 and 2 vCPU: guest NIC facts, ping, iperf3 to 864 private (1 and 4 flows, both
     directions), to 864's public address, to Clouvider Atlanta (internet, both directions), HTTP download
  2. N sandboxes at once (16, 64), 1 vCPU each, one iperf3 flow each to its own server port, both directions
Prints one JSON line per measurement and a human summary line to stderr.
"""
import json, os, sys, threading, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path("/home/ubuntu/arm64-benchmark-1")
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")
os.environ.setdefault("RLP_HTTP_MAX_CONNECTIONS", "256")
os.environ.setdefault("RLP_HTTP_READ_TIMEOUT_S", "180")
from harness import rlp_client_tuning
rlp_client_tuning.apply()
import rlp_light_create_fleet as F

T = "atl1"; PRIV = "10.46.90.71"; PUB = os.environ.get("NODE864_PUB", "<node864-public>"); INET = "atl.speedtest.clouvider.net"
client = F.build_client(T)
OUT = open(sys.argv[1], "a")

def rec(**kw):
    kw["t"] = time.time(); OUT.write(json.dumps(kw) + "\n"); OUT.flush()
    print(" ".join(f"{k}={v}" for k, v in kw.items() if k not in ("t", "raw")), file=sys.stderr, flush=True)

def create(cpu, idx):
    return client.create(F.build_params(target=T, image="alpine:3.20", cpu=cpu, memory=1.0, disk=1.0, idx=idx), timeout=300)

def sh(sb, cmd, timeout=120):
    r = sb.process.exec(cmd, timeout=timeout); return r.exit_code, r.result

def setup(sb):
    for _ in range(3):
        code, out = sh(sb, "apk add --no-cache iperf3 curl >/tmp/apk.log 2>&1; which iperf3 curl", 180)
        if code == 0 and "iperf3" in out: return True
        time.sleep(2)
    rec(kind="setup-failed", out=out[-300:]); return False

def iperf(sb, host, port, flows=1, rev=False, secs=10, omit=2):
    code, out = sh(sb, f"iperf3 -4 -c {host} -p {port} -P {flows} -t {secs} -O {omit} {'-R' if rev else ''} -J", secs + 60)
    try:
        d = json.loads(out)
        if "error" in d: return None, d["error"]
        return d["end"]["sum_received"]["bits_per_second"] / 1e9, d["end"]["sum_sent"].get("retransmits")
    except Exception as e:
        return None, (out or str(e))[-200:]

def iperf_inet(sb, rev, flows):
    for p in range(5201, 5210):
        g, x = iperf(sb, INET, p, flows, rev)
        if g is not None: return g, x, p
    return None, x, None

def delete(sb):
    try: client.delete(sb)
    except Exception:
        try: sb.delete()
        except Exception as e: rec(kind="delete-failed", err=str(e)[:200])

# ---- 1. single sandbox
for cpu in (1, 2):
    sb = create(cpu, 9000 + cpu)
    try:
        if not setup(sb): continue
        _, facts = sh(sb, "echo nproc=$(nproc) mtu=$(cat /sys/class/net/eth0/mtu) "
                          "ip=$(ip -4 -o a show eth0 | awk '{print $4}') "
                          "egress=$(curl -s -m 5 https://1.1.1.1/cdn-cgi/trace | grep -E '^(ip|colo)=' | tr '\\n' ' ')")
        rec(kind="facts", cpu=cpu, facts=facts.strip())
        for host in (PRIV, "1.1.1.1"):
            _, p = sh(sb, f"ping -q -c 50 -i 0.2 {host} 2>&1 | tail -1")
            rec(kind="ping", cpu=cpu, host=host, rtt=p.strip())
        for host, label in ((PRIV, "node864-private"), (PUB, "node864-public")):
            for flows in (1, 4):
                for rev in (False, True):
                    g, x = iperf(sb, host, 5201, flows, rev)
                    rec(kind="iperf", cpu=cpu, path=label, flows=flows,
                        dir="node->sandbox" if rev else "sandbox->node", gbps=None if g is None else round(g, 2), retrans=x)
        for rev in (False, True):
            for flows in (1, 8):
                g, x, p = iperf_inet(sb, rev, flows)
                rec(kind="iperf", cpu=cpu, path="internet-clouvider-atl", flows=flows,
                    dir="internet->sandbox" if rev else "sandbox->internet", gbps=None if g is None else round(g, 2), retrans=x, port=p)
        _, o = sh(sb, "curl -s -o /dev/null -m 15 -w '%{http_code} %{speed_download}' https://speedtest.atlanta.linode.com/1GB-atlanta.bin", 60)
        c, s = o.split()
        rec(kind="http-dl", cpu=cpu, url="linode-atl-1GB", http=c, gbps=round(float(s) * 8 / 1e9, 2))
    finally:
        delete(sb)

# ---- 2. N sandboxes at once, one flow each to its own port on node 864
for n in (16, 64):
    with ThreadPoolExecutor(n) as ex:
        sbs = list(ex.map(lambda i: create(1, 9100 + i), range(n)))
        ok = list(ex.map(setup, sbs))
        if not all(ok): rec(kind="setup-partial", n=n, ok=sum(ok))
        for rev in (False, True):
            bar = threading.Barrier(n)
            def run(i):
                bar.wait(); return iperf(sbs[i], PRIV, 5201 + i, 1, rev, secs=15, omit=3)
            res = list(ex.map(run, range(n)))
            g = [r[0] for r in res if r[0] is not None]
            rec(kind="iperf-many", n=n, cpu=1, path="node864-private", dir="node->sandboxes" if rev else "sandboxes->node",
                total_gbps=round(sum(g), 1), per_sandbox_min=round(min(g), 2) if g else None,
                per_sandbox_max=round(max(g), 2) if g else None, failed=n - len(g),
                errors=[r[1] for r in res if r[0] is None][:3])
        list(ex.map(delete, sbs))
rec(kind="done")

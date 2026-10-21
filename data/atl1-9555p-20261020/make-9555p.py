#!/usr/bin/env python3
"""Build BASELINE-EPYC9555P-FIXES-20261020.json from the raw suite data in suite-atl1.tgz.

Usage: python3 make-9555p.py [suite-atl1.tgz] > BASELINE-EPYC9555P-FIXES-20261020.json
Startup numbers come from the mpfleet summary line of each run; ladder numbers from the harness summary rows.
"""
import json, re, sys, tarfile

tgz = sys.argv[1] if len(sys.argv) > 1 else "suite-atl1.tgz"
startup, ladders = [], {}
with tarfile.open(tgz) as t:
    for m in sorted(t.getmembers(), key=lambda m: m.name):
        mo = re.search(r"/startup-(\d+)-(idle|agent)-(\d+)\.jsonl$", m.name)
        if mo:
            rows = [json.loads(l) for l in t.extractfile(m) if l.strip()]
            s = [r for r in rows if r.get("type") == "summary"][-1]
            startup.append({"count": int(mo[1]), "image": mo[2], "rep": int(mo[3]), "ok": s["ok"], "failed": s["failed"],
                            "all_ready_s": round(s["ready_wall_s"], 2), "create_p50_s": round(s["create_p50_s"], 2),
                            "create_p95_s": round(s["create_p95_s"], 2), "post_p50_s": round(s["post_p50_s"], 2)})
        mo = re.search(r"/(ladder-[\d-]+)\.jsonl$", m.name)
        if mo:
            for l in t.extractfile(m):
                r = json.loads(l)
                if r.get("type") == "summary":
                    ladders.setdefault(mo[1], []).append({k: r[k] for k in (
                        "concurrency", "runs", "failures", "throughput_per_sec", "p50_ms", "p95_ms", "p99_ms", "max_ms")})
json.dump({
    "host": "atl1node853.mgmt.atl1.paperspace.com (Paperspace ATL1, DigitalOcean; bare-metal HPE ProLiant DL325 Gen11), 1x AMD EPYC 9555P 64C/128T, 755 GiB, kernel 6.8.0-139-generic",
    "build": {"runner": "739fc73a116d", "api": "93fa5e93bf20", "firecracker": "2fd0171309af", "guest_kernel": "a3ae79b93a20",
              "initdisk": "4e59e8441b7a", "note": "byte-identical to the EPYC 9575F baseline"},
    "fixes": "ON (initdisk=nofsync cgroup_pool=1400 neigh=1 backlog=4096)",
    "date": "2026-10-20", "startup": startup, "ladders": ladders,
}, sys.stdout, indent=1)
print()

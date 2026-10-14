#!/usr/bin/env python3
"""Multi-process create-ready: same per-sandbox logic as scripts/rlp_light_create_fleet.py, split over N processes.

Each worker process is forked AFTER the imports, builds its OWN client (own HTTP pool), runs count/N threads,
and starts on a shared barrier. Times are absolute (time.time) so the all-ready wall spans every process.
usage: mpfleet.py --procs N --count 1000 --output out.jsonl
"""
import argparse, json, multiprocessing as mp, os, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")
os.environ.setdefault("RLP_HTTP_MAX_CONNECTIONS", "1024")
from harness import rlp_client_tuning
rlp_client_tuning.apply()
import rlp_light_create_fleet as F
from rlp.sandbox import Sandbox

IMAGE = "dtgraviet/vera-agent-benchmark:v3"

def worker(wid, idxs, barrier, q, target, probe_timeout, timeout):
    client = F.build_client(target)            # per-process client + HTTP pool
    tls = threading.local(); orig = Sandbox.wait_until_started
    def timed_wait(self, timeout=60):
        t = time.perf_counter()
        try: orig(self, timeout)
        finally: tls.wait_s = time.perf_counter() - t
    Sandbox.wait_until_started = timed_wait
    def one(i):
        tls.wait_s = 0.0
        t_abs0 = time.time(); t0 = time.perf_counter()
        sb = client.create(F.build_params(target=target, image=IMAGE, cpu=0.025, memory=0.0625, disk=1.0, idx=i), timeout=timeout)
        create_s = time.perf_counter() - t0; wait_s = float(getattr(tls, "wait_s", 0.0))
        tp = time.perf_counter(); r = sb.process.exec("echo ready", timeout=probe_timeout); probe_s = time.perf_counter() - tp
        if int(r.exit_code or 0) != 0 or "ready" not in (r.result or "").lower():
            raise RuntimeError(f"probe failed {r.exit_code} {r.result!r}")
        return {"type": "sandbox", "idx": i, "proc": wid, "status": "ok", "sandbox_id": F._sandbox_id(sb),
                "create_s": create_s, "post_s": max(0.0, create_s - wait_s), "wait_s": wait_s, "probe_s": probe_s,
                "t_start": t_abs0, "t_end": time.time(), "error": None}
    barrier.wait()
    t_go = time.time()
    out = []
    with ThreadPoolExecutor(max_workers=len(idxs)) as pool:
        futs = {pool.submit(one, i): i for i in idxs}
        for f in as_completed(futs):
            try: out.append(f.result())
            except Exception as e:
                out.append({"type": "sandbox", "idx": futs[f], "proc": wid, "status": "failed", "error": f"{type(e).__name__}:{e}"[:300], "t_end": time.time()})
    q.put((wid, t_go, out))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--procs", type=int, required=True); ap.add_argument("--count", type=int, default=1000)
    ap.add_argument("--target", default="vera"); ap.add_argument("--output", required=True)
    ap.add_argument("--timeout", type=int, default=180); ap.add_argument("--probe-timeout", type=int, default=60)
    a = ap.parse_args()
    a.procs = max(1, min(a.procs, a.count))  # an empty shard would crash its worker and hang the barrier
    ctx = mp.get_context("fork")
    barrier = ctx.Barrier(a.procs + 1); q = ctx.Queue()
    shards = [list(range(a.count))[w::a.procs] for w in range(a.procs)]
    ps = [ctx.Process(target=worker, args=(w, shards[w], barrier, q, a.target, a.probe_timeout, a.timeout)) for w in range(a.procs)]
    for p in ps: p.start()
    barrier.wait(); t_go = time.time()
    res = [q.get() for _ in ps]
    for p in ps: p.join()
    recs = [r for _, _, out in res for r in out]
    ok = [r for r in recs if r["status"] == "ok"]
    gos = [g for _, g, _ in res]
    wall = max(r["t_end"] for r in recs) - t_go
    qq = lambda xs, p: sorted(xs)[min(len(xs) - 1, int(p * len(xs)))] if xs else float("nan")
    summ = {"type": "summary", "procs": a.procs, "sandboxes_requested": a.count, "ok": len(ok), "failed": len(recs) - len(ok),
            "ready_wall_s": wall, "start_skew_s": max(gos) - min(gos),
            "create_p50_s": qq([r["create_s"] for r in ok], .5), "create_p95_s": qq([r["create_s"] for r in ok], .95),
            "post_p50_s": qq([r["post_s"] for r in ok], .5), "post_p95_s": qq([r["post_s"] for r in ok], .95),
            "wait_p50_s": qq([r["wait_s"] for r in ok], .5), "probe_p50_s": qq([r["probe_s"] for r in ok], .5)}
    with open(a.output, "w") as fh:
        fh.write(json.dumps({"type": "meta", "procs": a.procs, "count": a.count, "threads_per_proc": [len(s) for s in shards]}) + "\n")
        for r in recs: fh.write(json.dumps(r) + "\n")
        fh.write(json.dumps(summ) + "\n")
    print(json.dumps(summ), flush=True)

if __name__ == "__main__":
    main()

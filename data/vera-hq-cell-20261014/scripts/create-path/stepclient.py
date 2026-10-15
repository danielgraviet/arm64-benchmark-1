"""Per-step create timing client (raw HTTP, ns timestamps, no SDK polling).

Per sandbox: POST /vms -> GET /vms/{id}?wait=running long-poll until running -> one exec through the toolbox proxy
(POST {toolbox}/{id}/process/execute, rlp-rs-0.4.x daemon route). Optional timed DELETE in sequential mode.

  seq:   python stepclient.py --mode seq   --count 100 --image alpine:3.20 --out x.jsonl
  burst: python stepclient.py --mode burst --count 1000 --procs 16 --image alpine:3.20 --out x.jsonl
"""
import argparse, json, multiprocessing as mp, os, sys, threading, time
from concurrent.futures import ThreadPoolExecutor
import httpx

API = os.environ.get("STEP_API", "http://127.0.0.1:8088")
TOOLBOX = os.environ.get("STEP_TOOLBOX", "http://127.0.0.1:9000/toolbox")


def key():
    for l in open(os.path.expanduser("~/arm64-benchmark-1/.env")):
        if l.startswith("VERA_RLP_API_KEY="):
            return l.split("=", 1)[1].strip().strip('"')
    raise SystemExit("no VERA_RLP_API_KEY")


def body(image, i):
    return {"image": image, "region": "vera", "name": f"step-{os.getpid()}-{i}", "cpu": 0.025, "mem_mib": 64,
            "scratch_mib": 1024, "cpu_arch": "arm64", "cpu_type": "vera"}


def one(api, tb, image, i, do_delete):
    ns = time.time_ns
    r = {"type": "sandbox", "idx": i, "pid": os.getpid()}
    try:
        r["t_post_send"] = ns()
        p = api.post("/vms", json=body(image, i))
        r["t_post_resp"] = ns(); r["post_http"] = p.status_code
        p.raise_for_status(); pj = p.json()
        vid, tok = pj["vm_id"], pj.get("access_token")
        r["vm_id"] = vid; r["post_status"] = pj.get("status")
        polls, st, deadline = 0, None, time.time() + 120
        while time.time() < deadline:
            polls += 1
            g = api.get(f"/vms/{vid}", params={"wait": "running", "timeout_ms": 30000}, timeout=40)
            st = g.json().get("status") if g.status_code == 200 else f"http{g.status_code}"
            if st in ("running", "failed", "error", "stopped", "deleted"):
                break
        r["t_running_seen"] = ns(); r["polls"] = polls; r["status_seen"] = st
        if st != "running":
            r["status"] = "failed"; r["error"] = f"status={st}"; return r
        r["t_exec_send"] = ns()
        e = tb.post(f"/{vid}/process/execute", json={"command": "echo ready", "timeout": 30},
                    headers={"Authorization": f"Bearer {tok}"} if tok else None, timeout=40)
        r["t_exec_resp"] = ns(); r["exec_http"] = e.status_code
        ok = e.status_code == 200 and "ready" in (e.json().get("result") or "")
        r["status"] = "ok" if ok else "failed"
        if not ok:
            r["error"] = f"exec http={e.status_code} body={e.text[:120]}"
        if do_delete:
            r["t_del_send"] = ns(); d = api.delete(f"/vms/{vid}"); r["t_del_resp"] = ns(); r["del_http"] = d.status_code
    except Exception as ex:  # noqa: BLE001
        r["status"] = "failed"; r["error"] = f"{type(ex).__name__}: {str(ex)[:160]}"; r["t_fail"] = ns()
    return r


def clients(k, pool):
    lim = httpx.Limits(max_connections=pool, max_keepalive_connections=pool)
    api = httpx.Client(base_url=API, headers={"Authorization": f"Bearer {k}"}, limits=lim, timeout=60)
    tb = httpx.Client(base_url=TOOLBOX, limits=lim, timeout=60)
    return api, tb


def worker(w, idxs, barrier, q, image, k):
    api, tb = clients(k, max(8, len(idxs)))
    api.get("/health")  # warm the connection pool
    if os.environ.get("STEP_PREWARM") == "1":
        # open one keep-alive connection per worker thread BEFORE the timed burst (long-lived clients)
        with ThreadPoolExecutor(max_workers=len(idxs)) as ex:
            list(ex.map(lambda _: api.get("/health"), range(len(idxs))))
        time.sleep(2)
    barrier.wait()
    with ThreadPoolExecutor(max_workers=len(idxs)) as ex:
        out = list(ex.map(lambda i: one(api, tb, image, i, False), idxs))
    q.put(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["seq", "burst"], required=True)
    ap.add_argument("--count", type=int, default=100); ap.add_argument("--procs", type=int, default=16)
    ap.add_argument("--image", default="alpine:3.20"); ap.add_argument("--gap", type=float, default=0.5)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(); k = key(); recs = []
    t0 = time.time_ns()
    if a.mode == "seq":
        api, tb = clients(k, 8); api.get("/health")
        for i in range(a.count):
            recs.append(one(api, tb, a.image, i, True)); time.sleep(a.gap)
    else:
        a.procs = max(1, min(a.procs, a.count))
        ctx = mp.get_context("fork"); barrier = ctx.Barrier(a.procs + 1); q = ctx.Queue()
        shards = [list(range(a.count))[w::a.procs] for w in range(a.procs)]
        ps = [ctx.Process(target=worker, args=(w, shards[w], barrier, q, a.image, k)) for w in range(a.procs)]
        for p in ps: p.start()
        barrier.wait(); t0 = time.time_ns()
        for _ in ps: recs.extend(q.get())
        for p in ps: p.join()
    ok = sum(1 for r in recs if r.get("status") == "ok")
    with open(a.out, "w") as fh:
        fh.write(json.dumps({"type": "meta", "mode": a.mode, "count": a.count, "procs": a.procs, "image": a.image,
                             "t_start": t0}) + "\n")
        for r in recs: fh.write(json.dumps(r) + "\n")
        fh.write(json.dumps({"type": "summary", "ok": ok, "failed": len(recs) - ok}) + "\n")
    print(json.dumps({"mode": a.mode, "image": a.image, "ok": ok, "failed": len(recs) - ok}), flush=True)


if __name__ == "__main__":
    main()

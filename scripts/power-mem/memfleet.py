#!/usr/bin/env python3
"""memfleet.py - memory-bandwidth workload across N concurrent sandboxes (one vCPU each).

Phase 1 (not timed): create N sandboxes from IMAGE (default gcc:14), upload memtest.c (base64 through exec), compile it.
Phase 2: all processes pass a barrier, then every sandbox runs `memtest N_ELEM SECS` at the same moment.
Aggregate bandwidth = sum of per-sandbox mean GB/s; valid when the runs overlap (start_skew_s << SECS; reported).
Run from the harness directory (~/arm64-benchmark-1) like mpfleet.py:
  uv run python memfleet.py --target vera --count 176 --secs 30 --elems 16777216 --output out.jsonl
"""
import argparse, base64, json, multiprocessing as mp, os, sys, threading, time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path.cwd()
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "scripts"))
from dotenv import load_dotenv
load_dotenv(ROOT / ".env")
os.environ.setdefault("RLP_HTTP_MAX_CONNECTIONS", "1024")
from harness import rlp_client_tuning
rlp_client_tuning.apply()
import rlp_light_create_fleet as F
from harness.rlp_create import build_rlp_resources
from rlp import CreateSandboxFromImageParams

SRC = Path(os.environ.get("MEMTEST_SRC", Path(__file__).with_name("memtest.c"))).read_bytes()
B64 = base64.b64encode(SRC).decode()
IMAGE = os.environ.get("MEMFLEET_IMAGE", "gcc:14")

def params(target, i):
    kw = {"image": IMAGE, "name": f"memfleet-{i}",
          "resources": build_rlp_resources(cpu=0.025, memory=1.0, disk=1.0, cpu_max=1, memory_max=4)}
    if target == "vera":
        kw["cpu_arch"] = "arm64"; kw["cpu_type"] = "vera"
    return CreateSandboxFromImageParams(**kw)

def worker(wid, idxs, b_prep, b_go, q, a):
    client = F.build_client(a.target)
    sbs = {}; out = []
    def prep(i):
        t0 = time.time()
        sb = client.create(params(a.target, i), timeout=a.timeout)
        r = sb.process.exec(f"sh -c 'echo {B64} | base64 -d > /tmp/m.c && gcc -O3 -o /tmp/m /tmp/m.c && echo built'", timeout=300)
        if int(r.exit_code or 0) != 0 or "built" not in (r.result or ""):
            raise RuntimeError(f"compile failed {r.exit_code} {(r.result or '')[:200]!r}")
        return i, sb, time.time() - t0
    with ThreadPoolExecutor(max_workers=max(1, len(idxs))) as pool:
        for f in as_completed([pool.submit(prep, i) for i in idxs]):
            try:
                i, sb, dt = f.result(); sbs[i] = sb
            except Exception as e:
                out.append({"type": "sandbox", "proc": wid, "status": "prep_failed", "error": f"{type(e).__name__}:{e}"[:300]})
    b_prep.wait()          # every process finished phase 1
    b_go.wait()            # main releases everyone at once
    def run(i, sb):
        t = time.time()
        r = sb.process.exec(f"/tmp/m {a.elems} {a.secs}", timeout=int(a.secs) + 120)
        rec = {"type": "sandbox", "idx": i, "proc": wid, "sandbox_id": F._sandbox_id(sb), "t_exec_send": t, "t_exec_done": time.time()}
        try:
            rec.update(json.loads((r.result or "").strip().splitlines()[-1])); rec["status"] = "ok" if "mean_gbs" in rec else "bad_output"
        except Exception as e:
            rec.update({"status": "bad_output", "error": f"{e}: {(r.result or '')[:200]!r}"})
        return rec
    with ThreadPoolExecutor(max_workers=max(1, len(sbs))) as pool:
        for f in as_completed([pool.submit(run, i, sb) for i, sb in sbs.items()]):
            try: out.append(f.result())
            except Exception as e: out.append({"type": "sandbox", "proc": wid, "status": "run_failed", "error": f"{type(e).__name__}:{e}"[:300]})
    if not a.keep:
        with ThreadPoolExecutor(max_workers=max(1, len(sbs))) as pool:
            def rm(sb):
                try: sb.delete()
                except Exception: pass
            list(pool.map(rm, sbs.values()))
    q.put(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True); ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--procs", type=int, default=16); ap.add_argument("--secs", type=float, default=30)
    ap.add_argument("--elems", type=int, default=1 << 24); ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--keep", action="store_true"); ap.add_argument("--output", required=True)
    a = ap.parse_args(); a.procs = max(1, min(a.procs, a.count))
    ctx = mp.get_context("fork"); b_prep = ctx.Barrier(a.procs + 1); b_go = ctx.Barrier(a.procs + 1); q = ctx.Queue()
    shards = [list(range(a.count))[w::a.procs] for w in range(a.procs)]
    ps = [ctx.Process(target=worker, args=(w, shards[w], b_prep, b_go, q, a)) for w in range(a.procs)]
    for p in ps: p.start()
    t_prep0 = time.time(); b_prep.wait(); t_prep = time.time() - t_prep0
    time.sleep(2); t_go = time.time(); b_go.wait()
    recs = [r for _ in ps for r in q.get()]
    for p in ps: p.join()
    ok = [r for r in recs if r.get("status") == "ok"]
    starts = [r["t_start"] for r in ok]; ends = [r["t_end"] for r in ok]
    summ = {"type": "summary", "count": a.count, "ok": len(ok), "failed": len(recs) - len(ok), "secs": a.secs, "elems": a.elems,
            "array_mib_per_sandbox": round(3 * a.elems * 8 / 1048576), "prep_s": round(t_prep, 1),
            "aggregate_gbs": round(sum(r["mean_gbs"] for r in ok), 2),
            "per_sandbox_gbs_p50": round(sorted(r["mean_gbs"] for r in ok)[len(ok) // 2], 3) if ok else None,
            "per_sandbox_gbs_min": round(min((r["mean_gbs"] for r in ok), default=0), 3),
            "start_skew_s": round(max(starts) - min(starts), 3) if ok else None,
            "overlap_s": round(min(ends) - max(starts), 3) if ok else None,
            "t_go": t_go, "t_first_start": min(starts) if ok else None, "t_last_end": max(ends) if ok else None}
    with open(a.output, "w") as fh:
        fh.write(json.dumps({"type": "meta", "target": a.target, "image": IMAGE, "procs": a.procs, "count": a.count}) + "\n")
        for r in recs: fh.write(json.dumps(r) + "\n")
        fh.write(json.dumps(summ) + "\n")
    print(json.dumps(summ), flush=True)

if __name__ == "__main__":
    main()

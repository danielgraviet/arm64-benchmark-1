"""Build the comparison baseline JSON from the raw run data on HQ Vera (no hand transcription)."""
import glob, json, re, statistics

B = "/mnt/data/bench/"
FB = B + "fixes-bench-20261014_184145/"


def q(v, p):
    v = sorted(v)
    return round(v[min(len(v) - 1, int(p * len(v)))], 3) if v else None


def mpfleet(path):
    recs = [json.loads(l) for l in open(path)]
    s = recs[-1]
    ok = [r for r in recs if r.get("type") == "sandbox" and r.get("status") == "ok"]
    c = [r["create_s"] for r in ok]
    return {"ok": s["ok"], "failed": s["failed"], "all_ready_s": round(s["ready_wall_s"], 3),
            "create_p50_s": q(c, .5), "create_p90_s": q(c, .9), "create_p95_s": q(c, .95), "create_p99_s": q(c, .99),
            "post_p50_s": round(s["post_p50_s"], 3)}


log = open(FB + "log").read()
overflow = {(m[0], m[1], m[2]): int(m[3]) for m in re.findall(r"STARTUP flags=(\w+) image=(\w+) rep=(\d) .*?overflows=(\d+)", log)}
startup = {}
for flags in ("off", "on"):
    for img in ("idle", "agent"):
        runs = []
        for rep in (1, 2, 3):
            f = f"{FB}startup-{flags}-{img}-{rep}.jsonl"
            r = mpfleet(f); r["rep"] = rep; r["listen_overflows"] = overflow.get((flags, img, str(rep)))
            runs.append(r)
        startup.setdefault(img, {})[flags] = runs

tput = {}
for flags in ("off", "on"):
    rows = []
    for l in open(f"{FB}tput-{flags}.jsonl"):
        r = json.loads(l)
        if r.get("type") == "summary":
            rows.append({"concurrency": r["concurrency"], "runs": r["runs"], "failures": r["failures"],
                         "jobs_per_s": r["throughput_per_sec"], "p50_s": round(r["p50_ms"] / 1000, 2),
                         "p99_s": round(r["p99_ms"] / 1000, 2)})
    tput[flags] = rows

# per-step create path (long-poll client), from the patched-build arms
STEPS = [("client_to_api", "t_post_send", "audit"), ("api_pre_txn", "audit", "db_begin"),
         ("api_txn_publish_commit_response", "db_begin", "t_post_resp"), ("queue_to_runner", "js_store", "r_recv"),
         ("runner_boot_prep", "r_create_log", "r_tnet"), ("scratch_initdisk", None, "scratch_cp_ms"),
         ("fc_spawn_socket", None, "fc_start_ms"), ("snapshot_load", None, "load_ms"),
         ("toolbox_accept", None, "toolbox_wait_ms"), ("cgroup_register_trigger", None, "clone_other"),
         ("api_longpoll_answer", "ev_running", "t_running_seen"),
         ("TOTAL_post_to_running", "t_post_send", "t_running_seen"), ("TOTAL_post_to_first_exec", "t_post_send", "t_exec_resp")]


def val(x, a, b):
    if a is None:
        return x.get(b)
    return (x[b] - x[a]) / 1e6 if x.get(a) is not None and x.get(b) is not None else None


def steps(tags):
    rows, runs = [], []
    for t in tags:
        for d in sorted(glob.glob(f"{B}steps-*-{t}")):
            if d.split("steps-")[1][:15] < "20261014_163546":
                continue
            rows += [json.loads(l) for l in open(d + "/steps.jsonl")]; runs.append(d.split("/")[-1])
    out = {"runs": runs, "n": len(rows)}
    for name, a, b in STEPS:
        v = [y for y in (val(x, a, b) for x in rows) if y is not None]
        out[name] = {"p50_ms": q(v, .5), "p90_ms": q(v, .9), "p99_ms": q(v, .99), "max_ms": q(v, 1.0)}
    return out


def tw(tag):
    d = sorted(glob.glob(f"{B}steps-*-{tag}"))[-1]
    v = [int(m.group(1)) for m in (re.search(r"toolbox_wait_ms=(\d+)", l) for l in open(d + "/runner.log")) if m]
    return {"n": len(v), "stalled_over_100ms": sum(1 for x in v if x > 100), "max_ms": max(v)}


baseline = {
    "name": "HQ Vera create path, four fixes OFF vs ON",
    "date_utc": "2026-10-14",
    "host": {"name": "HQ Vera", "ip": "10.96.8.228", "cpu": "NVIDIA Vera", "sockets": 2, "cores_per_socket": 88,
             "threads": 352, "kernel": "6.17.0-1032-nvidia-64k", "page_size": "64KiB", "preempt": "none",
             "power_cap_w_per_socket": 600, "placement": "unpinned (both sockets)"},
    "software": {"daytona_base_commit": "f0611fa13", "bench_build_patches": "patches/bench-build/",
                 "runner_sha256_12": "0fd55bab4ad6", "api_sha256_12": "1648ab971fe5",
                 "stock_runner_sha256_12": "353a4060945c", "stock_api_sha256_12": "c49d24e5ac54",
                 "daemon": "rlp-rs-0.4.1", "firecracker": "v1.16.1 (stock)", "guest_kernel": "6.12.34-rlp1-arm64",
                 "runner_env_common": {"RLP_FC_SOCK_WAIT_MS": 30000, "RLP_VM_CONCURRENCY": 512, "RLP_NETNS_POOL": 2100,
                                       "RLP_BALLOON": 0, "RLP_BURST_MAX_CPU": 1}},
    "fixes": {"off": "all flags unset (= stock behaviour)",
              "on": {"RLP_INITDISK_MODE": "nofsync", "RLP_CGROUP_POOL": 1400, "RLP_NEIGH_PERMANENT": 1,
                     "RLP_API_LISTEN_BACKLOG": 4096},
              "issues": {"RLP_INITDISK_MODE": "daytona/rlp#3260", "RLP_CGROUP_POOL": "daytona/rlp#3261",
                         "RLP_NEIGH_PERMANENT": "daytona/rlp#3265", "RLP_API_LISTEN_BACKLOG": "daytona/rlp#3269"}},
    "harness_benchmarks": {
        "method": {"startup": "mpfleet.py --procs 16 --count 1000, SDK polling 0.25s x1.5 -> 2s, RLP_HTTP_MAX_CONNECTIONS=1024, "
                              "RLP_HTTP_READ_TIMEOUT_S=120, probe 'echo ready'; sandbox 0.025 CPU / 64 MiB / 1 GiB disk / 1 vCPU",
                   "throughput": "main.py --benchmark agent --hold-then-exec --n 45 --seed 42 -E 8 --rlp-cpu 0.025 "
                                 "--rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 --rlp-disk 0.015625, "
                                 "RLP_HTTP_MAX_CONNECTIONS=512, RLP_HOLD_CREATE_BATCH=512, RLP_HTTP_READ_TIMEOUT_S=120",
                   "order": "off, on, off, on (interleaved); same binaries, flags only; preflight PASS before every rep",
                   "images": {"idle": "alpine:3.20", "agent": "dtgraviet/vera-agent-benchmark:v3"},
                   "script": "scripts/create-path/bench-fixes.sh", "raw": "fixes-bench.tgz"},
        "startup_1000": startup,
        "throughput_ladder": tput,
        "notes": ["throughput level 176 with fixes off (1.47 jobs/s) was held by 8 episodes wedged in guests that oopsed "
                  "after resume (daytona/rlp#3213); not a platform result",
                  "single failed sandboxes hold all_ready open (idle on rep1: 10.42 s; agent on rep1: 61.02 s)"]},
    "create_path_steps": {
        "method": "stepclient.py raw HTTP + server long-poll GET /vms/{id}?wait=running, 16 procs; per-step joins of "
                  "client, audit_logs, vms, JetStream ack timestamps (natstap), runner journal; idle image alpine:3.20",
        "burst_1000": {"off": steps(["ctl-1", "ctl-2", "ctl-3", "ctl-4"]), "on": steps(["all-n3", "all-n4"])},
        "sequential_60": {"off": steps(["seq-ctl"]), "on": steps(["seq-all"]),
                          "toolbox_stalls": {"off": tw("seq-ctl"), "on": tw("seq-all")}},
        "raw": ["patched-arms.tgz"]},
}
print(json.dumps(baseline, indent=1))

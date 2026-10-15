import json, glob, sys
B = "/mnt/data/bench/"
groups = {
  "unloaded (200 seq, alpine)": ["steps-*-seq-alpine"],
  "1k burst, alpine, disk scratch (4 runs)": ["steps-*-burst-alpine-1", "steps-*-burst-alpine-2", "steps-*-burst-alpine-disk-1", "steps-*-burst-alpine-diskB-1"],
  "1k burst, alpine, tmpfs scratch (2 runs)": ["steps-*-burst-alpine-tmpfsB-1", "steps-*-burst-alpine-tmpfsB-2"],
  "1k burst, agent image (entrypoint load)": ["steps-*-burst-agent"],
}
STEPS = [
 ("1 client -> API (HTTP, auth, audit)", "t_post_send", "audit"),
 ("2 API handler before DB txn", "audit", "db_begin"),
 ("3 API DB insert + JetStream publish", "db_begin", "js_store"),
 ("4 API commit + HTTP response", "js_store", "t_post_resp"),
 ("5 queue: JetStream -> runner handler", "js_store", "r_recv"),
 ("6-7 runner admission + image resolve", "r_recv", "r_create_log"),
 ("8 runner boot prep (manifest, template lookup)", "r_create_log", "r_tnet"),
 ("9a netns acquire", None, "netns_get_ms"),
 ("9b scratch cp + 16 MiB init-disk copy + fsync", None, "scratch_cp_ms"),
 ("9c Firecracker spawn (+cgroup join) + API socket", None, "fc_start_ms"),
 ("9d snapshot load + resume", None, "load_ms"),
 ("9e guest toolbox port accepts", None, "toolbox_wait_ms"),
 ("9f other: cgroup mkdir, register, trigger", None, "clone_other"),
 ("10 running event -> NATS", "r_emit", "ev_running"),
 ("11 API -> long-poll answers client", "ev_running", "t_running_seen"),
 ("TOTAL POST -> client sees running", "t_post_send", "t_running_seen"),
 ("12 first exec through proxy (echo ready)", "t_exec_send", "t_exec_resp"),
 ("TOTAL POST -> first exec done", "t_post_send", "t_exec_resp"),
]
def val(x, a, b):
    if a is None: return x.get(b)
    if x.get(a) is None or x.get(b) is None: return None
    return (x[b] - x[a]) / 1e6
q = lambda v, p: sorted(v)[min(len(v)-1, int(p*len(v)))] if v else float("nan")
data = {}
for g, pats in groups.items():
    rows, dirs = [], []
    for p in pats:
        for d in sorted(glob.glob(B + p)):
            if d.endswith("-aborted"): continue
            dirs.append(d.split("/")[-1]); rows += [json.loads(l) for l in open(d + "/steps.jsonl")]
    data[g] = (rows, dirs)
hdr = "| step | " + " | ".join(f"{g} p50 / p90" for g in groups) + " |"
print(hdr); print("|" + "---|" * (len(groups) + 1))
for name, a, b in STEPS:
    cells = []
    for g in groups:
        v = [y for y in (val(x, a, b) for x in data[g][0]) if y is not None]
        cells.append(f"{q(v,.5):.1f} / {q(v,.9):.1f}" if v else "—")
    print(f"| {name} | " + " | ".join(cells) + " |")
print()
for g, (rows, dirs) in data.items(): print(f"- {g}: n={len(rows)} sandboxes from {', '.join(dirs)}")

"""Per-step comparison across measurement arms.  usage: arms-table.py <burst|seq>"""
import json, glob, sys, collections

MODE = sys.argv[1] if len(sys.argv) > 1 else "burst"
B = "/mnt/data/bench/"
BURST = [
    ("control (patched, flags off)", ["ctl-1", "ctl-2", "ctl-3", "ctl-4"]),
    ("+ init disk (nofsync)", ["nofsync"]),
    ("+ init disk (sparse)", ["sparse"]),
    ("+ cgroup pool", ["cgpool"]),
    ("+ API backlog 4096", ["backlog"]),
    ("ALL (nofsync, pool warm)", ["all-n3", "all-n4"]),
    ("ALL (sparse, pool warm)", ["all-s2"]),
]
SEQ = [("control", ["seq-ctl"]), ("+ permanent neighbour", ["seq-nei"]), ("ALL", ["seq-all"])]
STEPS = [
    ("1 client -> API (HTTP, auth, audit)", "t_post_send", "audit"),
    ("2 API handler before DB txn", "audit", "db_begin"),
    ("3+4 API DB insert, publish, commit, response", "db_begin", "t_post_resp"),
    ("5 queue: JetStream -> runner handler", "js_store", "r_recv"),
    ("8 runner boot prep", "r_create_log", "r_tnet"),
    ("9b scratch + init-disk copy", None, "scratch_cp_ms"),
    ("9c Firecracker spawn + API socket", None, "fc_start_ms"),
    ("9d snapshot load + resume", None, "load_ms"),
    ("9e guest toolbox port accepts", None, "toolbox_wait_ms"),
    ("9f cgroup mkdir, register, trigger", None, "clone_other"),
    ("11 API -> long-poll answers client", "ev_running", "t_running_seen"),
    ("TOTAL POST -> client sees running", "t_post_send", "t_running_seen"),
    ("TOTAL POST -> first exec done", "t_post_send", "t_exec_resp"),
]
groups = BURST if MODE == "burst" else SEQ


def val(x, a, b):
    if a is None:
        return x.get(b)
    if x.get(a) is None or x.get(b) is None:
        return None
    return (x[b] - x[a]) / 1e6


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * len(v)))] if v else float("nan")


data, meta = {}, {}
for label, tags in groups:
    rows, dirs = [], []
    for t in tags:
        for d in sorted(glob.glob(f"{B}steps-*-{t}")):
            stamp = d.split("steps-")[1][:15]
            if stamp < "20261014_163546":  # runs before the harness fix (arm env never applied)
                continue
            f = d + "/steps.jsonl"
            try:
                rows += [json.loads(l) for l in open(f)]
                dirs.append(d.split("-", 1)[-1])
            except FileNotFoundError:
                pass
    data[label] = rows
    meta[label] = (len(rows), len(dirs))

w = max(len(l) for l in data) + 2
print(f"{'step':46s}" + "".join(f"{l:>{w}s}" for l in data))
print(f"{'':46s}" + "".join(f"{'p50 / p90':>{w}s}" for l in data))
for name, a, b in STEPS:
    cells = []
    for label in data:
        v = [y for y in (val(x, a, b) for x in data[label]) if y is not None]
        cells.append(f"{q(v,.5):.0f} / {q(v,.9):.0f}" if v else "-")
    print(f"{name:46s}" + "".join(f"{c:>{w}s}" for c in cells))
print()
for label, (n, d) in meta.items():
    print(f"  {label}: n={n} sandboxes, {d} run(s)")

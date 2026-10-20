"""Join client / NATS tap / runner journal / DB timestamps per sandbox into a create-path timeline.

usage: steps-analyze.py <run_dir>    (expects client.jsonl, tap.tsv, runner.log, db.csv in run_dir)
Writes <run_dir>/steps.jsonl (per sandbox) and prints the per-step table. All clocks are the same host (HQ Vera).
"""
import csv, json, re, sys, datetime as dt
from collections import defaultdict

D = sys.argv[1]
MS = 1e6  # ns per ms


def jts(s):  # slog time=2026-10-14T14:07:22.803Z -> ns
    return int(dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() * 1e9)


client = {}
for l in open(f"{D}/client.jsonl"):
    r = json.loads(l)
    if r.get("type") == "sandbox" and r.get("vm_id"):
        client[r["vm_id"]] = r

db, seq2vm = {}, {}
for row in csv.DictReader(open(f"{D}/db.csv")):
    v = row["id"]
    db[v] = {k: (int(float(x) * 1000) if x not in ("", None) else None) for k, x in row.items() if k != "id" and k != "stream_seq"}
    if row.get("stream_seq"):
        seq2vm[row["stream_seq"]] = v
        db[v]["stream_seq"] = row["stream_seq"]

tap = defaultdict(dict)  # vm -> {key: ns}
for l in open(f"{D}/tap.tsv"):
    f = l.rstrip("\n").split("\t")
    if len(f) < 5:
        continue
    t, subj, vm, job, st = int(f[0]), f[1], f[2], f[3], f[4]
    if subj.startswith("$JS.ACK.JOBS."):
        p = subj.split(".")  # $JS ACK JOBS consumer delivered sseq cseq tm pending
        if len(p) >= 9:
            v = seq2vm.get(p[5])
            if v:
                tap[v].setdefault("js_store", int(p[7]))
                if st.startswith("+ACK"):
                    tap[v]["ack"] = t
                    tap[v]["deliveries"] = int(p[4])
                else:
                    tap[v][f"nak{p[4]}"] = t
    elif subj.startswith("jobs.vm.create") and vm:
        tap[vm].setdefault("job_pub_seen", t)
    elif subj.startswith("events.vm.") and vm:
        tap[vm].setdefault("ev_" + subj.split(".")[2], t)
    elif subj.startswith("events.job.") and vm:
        tap[vm].setdefault("job_" + subj.split(".")[2], t)

run = defaultdict(dict)
for l in open(f"{D}/runner.log", errors="replace"):
    m = re.search(r"time=(\S+) .*?msg=(\"boot-phases create\"|boot-phases|running-emit) vm_id=(\S+)(.*)", l)
    if not m:
        continue
    t, msg, vm, rest = jts(m.group(1)), m.group(2).strip('"'), m.group(3), m.group(4)
    kv = {k: int(x) for k, x in re.findall(r"(\w+)=(\d+)", rest)}
    if msg == "boot-phases create":
        run[vm]["create_log"] = t; run[vm]["c"] = kv
    elif msg == "boot-phases":
        run[vm]["boot_log"] = t; run[vm]["b"] = kv
    else:
        run[vm]["emit"] = kv.get("epoch_ms", 0) * MS

STEPS = [
    ("1 client -> API (HTTP + auth)", "t_post_send", "audit"),
    ("2 API handler before DB txn (validate, scaffold, idempotency, checks)", "audit", "db_begin"),
    ("3 API DB insert + JetStream publish (stored)", "db_begin", "js_store"),
    ("4 API commit + HTTP response", "js_store", "t_post_resp"),
    ("5 JetStream -> runner handler (queue, MaxAckPending, semaphore)", "js_store", "r_recv"),
    ("6 runner admission (orphan check, reserve, emits)", "r_recv", "r_emits"),
    ("7 runner image resolve", "r_emits", "r_create_log"),
    ("8 runner boot prep (manifest, validate, template lookup)", "r_create_log", "r_tnet"),
    ("9a clone: netns acquire", None, "netns_get_ms"),
    ("9b clone: scratch copy + links", None, "scratch_cp_ms"),
    ("9c clone: Firecracker spawn + API socket", None, "fc_start_ms"),
    ("9d clone: snapshot load + resume", None, "load_ms"),
    ("9e clone: toolbox port accepts (TCP :2280)", None, "toolbox_wait_ms"),
    ("9f clone: other (cgroup, register, deliveries, entrypoint trigger)", None, "clone_other"),
    ("10 running emit -> NATS (events.vm.running)", "r_emit", "ev_running"),
    ("11 API sees running -> long-poll answers client", "ev_running", "t_running_seen"),
    ("12 first exec via proxy (echo ready)", "t_exec_send", "t_exec_resp"),
]
TOTALS = [
    ("POST -> client sees running", "t_post_send", "t_running_seen"),
    ("POST -> first exec done", "t_post_send", "t_exec_resp"),
    ("runner: job stored -> running emit", "js_store", "r_emit"),
    ("runner: running emit -> job acked", "r_emit", "ack"),
    ("API: running event -> vms.started_at written (write-behind)", "ev_running", "db_started"),
]

rows = []
for vm, c in client.items():
    if c.get("status") != "ok":
        continue
    r, d, t = run.get(vm, {}), db.get(vm, {}), tap.get(vm, {})
    if "b" not in r or "c" not in r:
        continue
    b, cc = r["b"], r["c"]
    x = dict(c)
    x["audit"] = d.get("audit_us")  # already ns
    x["db_begin"] = d.get("created_us")
    x["db_started"] = d.get("started_us")
    x.update({k: t.get(k) for k in ("js_store", "ack", "ev_running", "ev_assigned", "ev_booting")})
    x["r_create_log"] = r["create_log"]
    x["r_emits"] = r["create_log"] - cc.get("manifest_ms", 0) * MS
    x["r_recv"] = x["r_emits"] - cc.get("emits_ms", 0) * MS
    x["r_tstart"] = r["boot_log"] - b["total_ms"] * MS
    x["r_tnet"] = r["boot_log"] - b["clone_ms"] * MS
    x["r_emit"] = r.get("emit")
    for k in ("netns_get_ms", "scratch_cp_ms", "fc_start_ms", "load_ms", "toolbox_wait_ms", "clone_ms", "total_ms"):
        x[k] = b.get(k)
    x["clone_other"] = b["clone_ms"] - sum(b.get(k, 0) for k in ("netns_get_ms", "scratch_cp_ms", "fc_start_ms", "load_ms", "toolbox_wait_ms"))
    x["deliver_ms_field"] = cc.get("deliver_ms")
    rows.append(x)

with open(f"{D}/steps.jsonl", "w") as fh:
    for x in rows:
        fh.write(json.dumps(x) + "\n")


def q(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(p * len(v)))] if v else float("nan")


def val(x, a, b):
    if a is None:
        return x.get(b)
    if x.get(a) is None or x.get(b) is None:
        return None
    return (x[b] - x[a]) / MS


def table(spec, title):
    print(f"\n{title}")
    print(f"{'step':74s} {'n':>5s} {'p50':>8s} {'p90':>8s} {'p99':>8s} {'max':>8s}  share_of_p50")
    tot = None
    for name, a, b in spec:
        v = [y for y in (val(x, a, b) for x in rows) if y is not None]
        if not v:
            print(f"{name:74s} {0:5d}"); continue
        print(f"{name:74s} {len(v):5d} {q(v,.5):8.1f} {q(v,.9):8.1f} {q(v,.99):8.1f} {max(v):8.1f}")


meta = json.loads(open(f"{D}/client.jsonl").readline())
fails = sum(1 for c in client.values() if c.get("status") != "ok")
print(f"run={D} mode={meta['mode']} image={meta['image']} count={meta['count']} procs={meta.get('procs')} "
      f"joined={len(rows)} client_failed={fails}")
table(STEPS, "Per-step latency (ms) — consecutive steps of one sandbox's create")
table(TOTALS, "Totals and off-path steps (ms)")
red = [x.get("deliveries", 1) for x in (tap.get(v, {}) for v in client) if x.get("deliveries", 1) > 1]
print(f"\njobs redelivered: {len(red)}")

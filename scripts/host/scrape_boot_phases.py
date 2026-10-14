#!/usr/bin/env python3
"""Scrape rlp-runner boot-phases from a journal dump into JSONL wall_share.

Usage:
  python3 scripts/host/scrape_boot_phases.py JOURNAL.txt [OUTPUT.jsonl]

Writes/appends a type=wall_share record with phase_p50_ms for scratch_cp_ms,
load_ms, fc_start_ms, toolbox_wait_ms, etc. When OUTPUT is a create-ready
JSONL with sandbox post_s/wait_s rows, also joins client wall shares.
"""
import json
import sys
from collections import defaultdict

phases = [
    "total_ms",
    "clone_ms",
    "netns_get_ms",
    "adopt_ms",
    "bind_ms",
    "scratch_cp_ms",
    "fc_start_ms",
    "load_ms",
    "toolbox_wait_ms",
]
queue_phases = ["deliver_ms", "emits_ms", "manifest_ms"]
provision_names = [
    "netns_get_ms",
    "adopt_ms",
    "bind_ms",
    "fc_start_ms",
    "scratch_cp_ms",
]
vals = defaultdict(list)
by_vm = {}

def field(line, name):
    key = name + "="
    at = line.find(key)
    if at < 0:
        return None
    rest = line[at + len(key) :]
    if rest.startswith('"'):
        end = rest.find('"', 1)
        return rest[1:end] if end > 0 else None
    token = rest.split()[0] if rest.split() else ""
    return token or None

def take_ms(line, name):
    raw = field(line, name)
    if raw is None:
        return None
    num = []
    for ch in raw:
        if ch.isdigit():
            num.append(ch)
        else:
            break
    if not num:
        return None
    return int("".join(num))

def vm_row(vm_id):
    row = by_vm.get(vm_id)
    if row is None:
        row = {}
        by_vm[vm_id] = row
    return row

with open(sys.argv[1], encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if "boot-phases" not in line:
            continue
        vm_id = field(line, "vm_id")
        if "template=hit" in line:
            for name in phases:
                ms = take_ms(line, name)
                if ms is None:
                    continue
                vals[name].append(ms)
                if vm_id:
                    vm_row(vm_id)[name] = ms
        elif "boot-phases create" in line:
            for name in queue_phases:
                ms = take_ms(line, name)
                if ms is None:
                    continue
                vals[name].append(ms)
                if vm_id:
                    vm_row(vm_id)[name] = ms

def pct(xs, p):
    if not xs:
        return 0
    xs = sorted(xs)
    i = round((p / 100) * (len(xs) - 1))
    return xs[i]

def share(part, whole):
    if not whole:
        return 0.0
    return 100.0 * part / whole

n = len(vals["total_ms"])
print(f"boot_phases n={n}")
slow_name = ""
slow_p50 = -1
for name in phases:
    xs = vals[name]
    if not xs:
        continue
    p50 = pct(xs, 50)
    if p50 > slow_p50:
        slow_name = name
        slow_p50 = p50
    print(
        f"  {name} p50={p50} p95={pct(xs, 95)} max={max(xs)} sum_s={sum(xs)/1000:.1f}"
    )
if slow_name:
    print(f"slowest_p50={slow_name} {slow_p50}ms")
for name in queue_phases:
    xs = vals[name]
    if not xs:
        continue
    print(
        f"  {name} p50={pct(xs, 50)} p95={pct(xs, 95)} max={max(xs)} sum_s={sum(xs)/1000:.1f}"
    )

rows = []
wall_s = None
jsonl_path = sys.argv[2] if len(sys.argv) > 2 else ""
if jsonl_path:
    try:
        with open(jsonl_path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") == "summary" and obj.get("ready_wall_s"):
                    wall_s = float(obj["ready_wall_s"])
                elif obj.get("type") == "sandbox" and obj.get("status") == "ok":
                    if obj.get("post_s") is None:
                        continue
                    rows.append(obj)
    except OSError as exc:
        print(f"WALL_SHARE jsonl unreadable: {exc}")

boot_p50 = pct(vals["total_ms"], 50) if vals["total_ms"] else 0
if wall_s:
    print(
        f"runner_boot_p50_ms={boot_p50} "
        f"runner_boot_p50_pct_of_wall={share(boot_p50 / 1000.0, wall_s):.2f}"
    )
elif vals["total_ms"] and boot_p50 < 1000:
    print(
        "gap=api_visibility runner boot p50 is under 1s. "
        "client create time is the wait until the API row says started."
    )

def finish_s(row):
    return float(row["create_s"]) + float(row.get("probe_s") or 0.0)

def client_line(label, row, wall):
    post = float(row["post_s"])
    wait = float(row["wait_s"])
    probe = float(row.get("probe_s") or 0.0)
    print(
        f"  {label} api_accept={post:.3f}s {share(post, wall):.1f}% "
        f"told_started={wait:.3f}s {share(wait, wall):.1f}% "
        f"probe={probe:.3f}s {share(probe, wall):.1f}%"
    )

def runner_bits(phases_for_vm):
    deliver = phases_for_vm.get("deliver_ms")
    total = phases_for_vm.get("total_ms")
    load = phases_for_vm.get("load_ms")
    toolbox = phases_for_vm.get("toolbox_wait_ms")
    provisioning = 0
    have_provision = False
    for name in provision_names:
        if name in phases_for_vm:
            provisioning += phases_for_vm[name]
            have_provision = True
    other = None
    if total is not None:
        named = (load or 0) + (toolbox or 0) + (provisioning if have_provision else 0)
        other = max(0, total - named)
    return deliver, provisioning if have_provision else None, load, toolbox, other, total

def runner_line(label, phases_for_vm, wait_s):
    deliver, provisioning, load, toolbox, other, _total = runner_bits(phases_for_vm)
    parts = [
        ("queued_before_runner", deliver),
        ("provisioning", provisioning),
        ("memory_move", load),
        ("guest_ready", toolbox),
        ("other", other),
    ]
    bits = []
    for name, ms in parts:
        if ms is None:
            continue
        sec = ms / 1000.0
        bits.append(f"{name}={sec:.3f}s {share(sec, wait_s):.1f}% of wait")
    if bits:
        print(f"  {label} " + " ".join(bits))

if wall_s and rows:
    ordered = sorted(rows, key=finish_s)
    last = ordered[-1]
    median = ordered[(len(ordered) - 1) // 2]
    print(f"WALL_SHARE wall_s={wall_s:.3f} n={len(rows)}")
    client_line("last", last, wall_s)
    client_line("median", median, wall_s)
    joined = 0
    for row in (last, median):
        sid = str(row.get("sandbox_id") or "")
        if sid and sid in by_vm:
            joined += 1
    if joined:
        print("WALL_SHARE runner joined to client ids")
        for label, row in (("last", last), ("median", median)):
            sid = str(row.get("sandbox_id") or "")
            hit = by_vm.get(sid)
            if not hit:
                print(f"  {label} no runner line for {sid}")
                continue
            runner_line(label, hit, float(row["wait_s"]))
    else:
        print("WALL_SHARE runner not joined. fleet p50 follows.")
        fleet = {name: pct(vals[name], 50) for name in phases + queue_phases if vals[name]}
        wait_med = float(median["wait_s"])
        runner_line("fleet_p50", fleet, wait_med)

# If a step holds a global kernel lock, the fleet wall is about
# count times that step, not the per-sandbox time. Network setup is the
# step the create path is expected to serialize. Memory move and guest
# boot can overlap.
serial_n = n or len(rows)
serial_buckets = [
    ("network", ["netns_get_ms", "adopt_ms", "bind_ms"]),
    ("scratch_disk", ["scratch_cp_ms"]),
    ("memory_move", ["load_ms"]),
    ("boot_until_ready", ["fc_start_ms", "toolbox_wait_ms"]),
]
if serial_n:
    print(f"SERIAL_SHARE n={serial_n} p50 times count, if that step cannot overlap")
    for label, names in serial_buckets:
        ms = 0
        seen = False
        for name in names:
            if vals[name]:
                ms += pct(vals[name], 50)
                seen = True
        if not seen:
            continue
        sec = serial_n * ms / 1000.0
        if wall_s:
            print(f"  {label} {sec:.1f}s {share(sec, wall_s):.0f}% of wall")
        else:
            print(f"  {label} {sec:.1f}s")

record = {
    "type": "wall_share",
    "source": "boot-phases",
    "boot_phases_n": n,
    "wall_s": wall_s,
    "runner_boot_p50_ms": boot_p50,
    "runner_boot_p50_pct_of_wall": (
        share(boot_p50 / 1000.0, wall_s) if wall_s else None
    ),
    "phase_p50_ms": {name: pct(vals[name], 50) for name in phases + queue_phases if vals[name]},
    "phase_p95_ms": {name: pct(vals[name], 95) for name in phases + queue_phases if vals[name]},
}
if wall_s and rows:
    ordered = sorted(rows, key=finish_s)
    last = ordered[-1]
    median = ordered[(len(ordered) - 1) // 2]

    def client_rec(row):
        post = float(row["post_s"])
        wait = float(row["wait_s"])
        probe = float(row.get("probe_s") or 0.0)
        return {
            "sandbox_id": row.get("sandbox_id"),
            "post_s": post,
            "wait_s": wait,
            "probe_s": probe,
            "post_pct_of_wall": share(post, wall_s),
            "wait_pct_of_wall": share(wait, wall_s),
            "probe_pct_of_wall": share(probe, wall_s),
        }

    record["last"] = client_rec(last)
    record["median"] = client_rec(median)
    for label, row in (("last", last), ("median", median)):
        sid = str(row.get("sandbox_id") or "")
        hit = by_vm.get(sid)
        if not hit:
            continue
        deliver, provisioning, load, toolbox, other, total = runner_bits(hit)
        record[label]["runner"] = {
            "queued_before_runner_ms": deliver,
            "provisioning_ms": provisioning,
            "memory_move_ms": load,
            "guest_ready_ms": toolbox,
            "other_ms": other,
            "total_ms": total,
        }
if serial_n:
    serial = {}
    for label, names in serial_buckets:
        ms = 0
        seen = False
        for name in names:
            if vals[name]:
                ms += pct(vals[name], 50)
                seen = True
        if not seen:
            continue
        sec = serial_n * ms / 1000.0
        serial[label] = {
            "p50_ms": ms,
            "serialized_s": sec,
            "pct_of_wall": share(sec, wall_s) if wall_s else None,
        }
    record["serial_share"] = serial
if jsonl_path and (wall_s or vals["total_ms"] or serial_n):
    with open(jsonl_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record) + "\n")
    print(f"WALL_SHARE written to {jsonl_path}")

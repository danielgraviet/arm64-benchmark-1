"""Runner timings for each 1000 and 2000 burst in a journal window.

GAP is clone_ms minus disk, memory, VM start, and toolbox. On Zen 5 that
remainder was the entrypoint release on port 2281.
"""

import datetime as dt
import re
import subprocess
import sys

since, until = sys.argv[1], sys.argv[2]


def journal(cmd):
    done = subprocess.run(cmd, capture_output=True, text=True)
    return done.stdout or ""


text = journal(
    ["journalctl", "-u", "rlp-runner", "--since", since, "--until", until, "--no-pager", "-o", "short-iso"]
)
if "boot-phases" not in text:
    text = journal(
        ["sudo", "-n", "journalctl", "-u", "rlp-runner", "--since", since, "--until", until, "--no-pager", "-o", "short-iso"]
    )

rows = []
for line in text.splitlines():
    if "boot-phases" not in line or "clone_ms" not in line:
        continue
    stamp = re.match(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", line)
    kv = dict(re.findall(r"(\w+)=([\w.:-]+)", line))
    if stamp is None or "clone_ms" not in kv:
        continue
    try:
        when = dt.datetime.fromisoformat(stamp.group(1))
        named = {key: int(kv.get(key, 0)) for key in ("scratch_cp_ms", "load_ms", "fc_start_ms", "toolbox_wait_ms")}
        rows.append((when, int(kv["clone_ms"]), named))
    except (TypeError, ValueError):
        continue

rows.sort()
clusters = []
current = []
for row in rows:
    if current and (row[0] - current[-1][0]).total_seconds() > 4:
        clusters.append(current)
        current = []
    current.append(row)
if current:
    clusters.append(current)


def qtile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(p * len(ordered)))]


shown = 0
for cluster in clusters:
    if len(cluster) < 900:
        continue
    shown += 1
    gaps = [row[1] - sum(row[2].values()) for row in cluster]
    med = {key: qtile([row[2][key] for row in cluster], 0.5) for key in cluster[0][2]}
    print(
        f"burst@{cluster[0][0]:%H:%M:%S} n={len(cluster):>4} "
        f"clone_p50={qtile([row[1] for row in cluster], 0.5):>6}ms "
        f"disk={med['scratch_cp_ms']}ms mem={med['load_ms']}ms "
        f"fc={med['fc_start_ms']}ms toolbox={med['toolbox_wait_ms']}ms "
        f"GAP_p50={qtile(gaps, 0.5)}ms GAP_p90={qtile(gaps, 0.9)}ms"
    )
if shown == 0:
    print(f"no 1000-wide burst in the journal between {since} and {until}")

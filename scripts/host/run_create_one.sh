#!/usr/bin/env bash
# Fifteen one-at-a-time creates. Same image and 16 MiB disk as the 1k note.
# Each sandbox is deleted before the next one starts.
# Writes client timings and the runner boot-phases line under daniel-focus-here.
#
#   ./o n
set -euo pipefail

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"
export PYTHONUNBUFFERED=1
export UV_NO_SYNC=1

REPEATS="${REPEATS:-15}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="daniel-focus-here/oci-vera-jsonl/single_create_${REPEATS}_${STAMP}.jsonl"
RAW="/tmp/vera-one-${STAMP}.txt"
mkdir -p "$(dirname "${OUT}")"
: > "${RAW}"

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

export RLP_API_URL="http://127.0.0.1:8088"
export RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export VERA_RLP_API_URL="http://127.0.0.1:8088"
export VERA_RLP_TOOLBOX_URL="http://127.0.0.1:9000/toolbox"
export VERA_RLP_TARGET="vera"

SINCE="$(date -u '+%Y-%m-%d %H:%M:%S')"
echo "=== ONE ${REPEATS} $(date -u +%Y-%m-%dT%H:%M:%SZ) output=${OUT} ==="

for i in $(seq 1 "${REPEATS}"); do
  log="/tmp/vera-one-${STAMP}-${i}.log"
  if ! UV_NO_SYNC=1 uv run python scripts/rlp_light_create_fleet.py \
      --target vera --count 1 --workers 1 \
      --image dtgraviet/vera-agent-benchmark:v3 \
      --cpu 0.025 --memory 0.0625 --disk 0.015625 \
      --probe 'echo ready' \
      --output "/tmp/vera-one-${STAMP}-${i}.jsonl" > "${log}" 2>&1; then
    echo "run ${i} failed" >&2
    tail -n 30 "${log}" >&2
    exit 1
  fi
  sid="$(python3 -c "
import json
p='/tmp/vera-one-${STAMP}-${i}.jsonl'
sid=''
for line in open(p):
    o=json.loads(line)
    if o.get('type')=='sandbox' and o.get('status')=='ok':
        sid=o.get('sandbox_id') or ''
print(sid)
")"
  phase="$(as_root journalctl -u rlp-runner --since "${SINCE}" --no-pager -o cat 2>/dev/null | grep "vm_id=${sid}" | grep 'template=hit' | tail -n 1 || true)"
  printf '%s\t%s\n' "${i}" "${phase}" >> "${RAW}"
  echo "run ${i} sandbox=${sid}"
  echo "  ${phase:-no boot-phases line}"
done

python3 - "${OUT}" "${RAW}" "${REPEATS}" <<'PY'
import json
import sys
from pathlib import Path

out, raw, repeats = sys.argv[1], sys.argv[2], int(sys.argv[3])

def take(line, name):
    key = name + "="
    at = line.find(key)
    if at < 0:
        return None
    rest = line[at + len(key):].split()[0]
    num = []
    for ch in rest:
        if ch.isdigit():
            num.append(ch)
        else:
            break
    return int("".join(num)) if num else None

def pct(xs, p):
    xs = sorted(v for v in xs if v is not None)
    if not xs:
        return None
    i = round((p / 100) * (len(xs) - 1))
    return xs[i]

stamp = Path(raw).name[len("vera-one-"):-len(".txt")]
rows = []
for row in Path(raw).read_text(encoding="utf-8").splitlines():
    if not row.strip():
        continue
    idx_s, _, phase = row.partition("\t")
    idx = int(idx_s)
    client_path = Path(f"/tmp/vera-one-{stamp}-{idx}.jsonl")
    client = {}
    if client_path.exists():
        for line in client_path.read_text(encoding="utf-8").splitlines():
            obj = json.loads(line)
            if obj.get("type") == "sandbox" and obj.get("status") == "ok":
                client = obj
                break
    names = [
        "total_ms",
        "clone_ms",
        "netns_get_ms",
        "scratch_cp_ms",
        "fc_start_ms",
        "load_ms",
        "toolbox_wait_ms",
    ]
    phases = {name: take(phase, name) for name in names}
    named = sum(
        phases[n] or 0
        for n in ("netns_get_ms", "scratch_cp_ms", "fc_start_ms", "load_ms", "toolbox_wait_ms")
    )
    clone = phases["clone_ms"]
    rec = {
        "type": "trial",
        "n": idx,
        "sandbox_id": client.get("sandbox_id"),
        "post_s": client.get("post_s"),
        "wait_s": client.get("wait_s"),
        "create_s": client.get("create_s"),
        "probe_s": client.get("probe_s"),
        "gap_ms": None if clone is None else clone - named,
        "boot_line": phase,
    }
    rec.update(phases)
    rows.append(rec)

def col(name):
    return [row.get(name) for row in rows]

summary = {
    "type": "summary",
    "repeats": repeats,
    "ok": len(rows),
    "create_s_p50": pct(col("create_s"), 50),
    "probe_s_p50": pct(col("probe_s"), 50),
    "total_ms_min": min((v for v in col("total_ms") if v is not None), default=None),
    "total_ms_p50": pct(col("total_ms"), 50),
    "total_ms_max": max((v for v in col("total_ms") if v is not None), default=None),
    "scratch_cp_ms_p50": pct(col("scratch_cp_ms"), 50),
    "load_ms_p50": pct(col("load_ms"), 50),
    "fc_start_ms_p50": pct(col("fc_start_ms"), 50),
    "toolbox_wait_ms_p50": pct(col("toolbox_wait_ms"), 50),
    "gap_ms_p50": pct(col("gap_ms"), 50),
}
meta = {
    "type": "meta",
    "kind": "single-create",
    "repeats": repeats,
    "image": "dtgraviet/vera-agent-benchmark:v3",
    "cpu": 0.025,
    "memory": 0.0625,
    "disk": 0.015625,
    "probe": "echo ready",
    "target": "vera",
}
with open(out, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(meta) + "\n")
    for row in rows:
        fh.write(json.dumps(row) + "\n")
    fh.write(json.dumps(summary) + "\n")
print(
    f"saved {out} host_p50_ms={summary['total_ms_p50']} "
    f"client_p50_s={summary['create_s_p50']}"
)
print(f"git add {out}")
PY

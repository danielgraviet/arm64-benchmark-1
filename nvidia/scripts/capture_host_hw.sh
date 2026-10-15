#!/usr/bin/env bash
# Capture as much Zen5 host / chip inventory as practical.
# Writes JSON + Markdown under OUT_DIR and nvidia/results/.
#
# Usage:  cd nvidia && ./o hw
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NVIDIA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT="$(cd "${NVIDIA_DIR}/.." && pwd)"
cd "${ROOT}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/profile.sh"
_zen5_apply_profile

export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT_DIR="${OUT_DIR:-daniel-focus-here/zen5-9755-jsonl}"
NVIDIA_OUT="${NVIDIA_DIR}/results"
mkdir -p "${OUT_DIR}" "${NVIDIA_OUT}"
JSON_OUT="${OUT_DIR}/host_hw_${STAMP}.json"
MD_OUT="${OUT_DIR}/host_hw_${STAMP}.md"
RAW_DIR="$(mktemp -d)"
trap 'rm -rf "${RAW_DIR}"' EXIT

log() { printf '[hw] %s\n' "$*"; }

run_cap() {
  local name="$1"
  shift
  local out="${RAW_DIR}/${name}.txt"
  if "$@" >"${out}" 2>&1; then
    :
  else
    echo "(command failed or unavailable)" >"${out}"
  fi
}

log "collecting host inventory"

run_cap uname uname -a
run_cap os_release cat /etc/os-release
run_cap lscpu lscpu
run_cap cpuinfo head -n 80 /proc/cpuinfo
run_cap meminfo grep -E '^(MemTotal|MemFree|MemAvailable|HugePages|Hugepagesize)' /proc/meminfo
run_cap numa numactl --hardware
run_cap dmidecode_system sudo -n dmidecode -t system
run_cap dmidecode_chassis sudo -n dmidecode -t chassis
run_cap dmidecode_processor sudo -n dmidecode -t processor
run_cap dmidecode_memory sudo -n dmidecode -t memory
run_cap dmidecode_bios sudo -n dmidecode -t bios
run_cap thermal bash -c 'ls /sys/class/thermal 2>/dev/null; for z in /sys/class/thermal/thermal_zone*; do [[ -e "$z" ]] || continue; echo "== $z =="; cat "$z/type" 2>/dev/null; cat "$z/temp" 2>/dev/null; done'
run_cap sensors sensors
run_cap cpufreq bash -c 'for f in /sys/devices/system/cpu/cpu0/cpufreq/*; do echo "$(basename "$f")=$(cat "$f" 2>/dev/null)"; done'
run_cap governors bash -c 'cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c'
run_cap block lsblk -o NAME,SIZE,TYPE,MODEL,ROTA,TRAN,MOUNTPOINT
run_cap nvme nvme list
run_cap df df -hT
run_cap nic bash -c 'ip -br link; DEV=$(ip -o route get 1.1.1.1 2>/dev/null | awk "{print \$5; exit}"); echo "default_dev=$DEV"; ethtool -i "$DEV" 2>/dev/null; ethtool "$DEV" 2>/dev/null | head -n 40'
run_cap neigh sysctl net.ipv4.neigh.default.gc_thresh1 net.ipv4.neigh.default.gc_thresh2 net.ipv4.neigh.default.gc_thresh3
run_cap kvm bash -c 'ls -l /dev/kvm; [[ -e /dev/kvm ]] && echo kvm_ok || echo kvm_missing'
run_cap firecracker bash -c 'command -v firecracker && firecracker --version | head -n1'
run_cap pagesize getconf PAGESIZE
run_cap rlp_units systemctl is-active rlp-api rlp-proxy rlp-runner
run_cap rlp_health curl -fsS -m 3 http://127.0.0.1:8088/health
run_cap fc_count bash -c 'pgrep -c firecracker || echo 0'

# Best-effort structured JSON via Python (stdlib only).
UV_NO_SYNC=1 uv run python - <<PY
import json, os, re, platform
from pathlib import Path
from datetime import datetime, timezone

raw = Path("${RAW_DIR}")
out_json = Path("${JSON_OUT}")
out_md = Path("${MD_OUT}")

def read(name: str) -> str:
    p = raw / f"{name}.txt"
    if not p.exists():
        return ""
    return p.read_text(errors="replace").strip()

def first_match(text: str, pattern: str, default=""):
    m = re.search(pattern, text, re.M | re.I)
    return m.group(1).strip() if m else default

lscpu = read("lscpu")
meminfo = read("meminfo")
dmi_mem = read("dmidecode_memory")
dmi_sys = read("dmidecode_system")
dmi_chassis = read("dmidecode_chassis")
dmi_cpu = read("dmidecode_processor")

dimms = []
for block in re.split(r"\nMemory Device\n", dmi_mem):
    if "Size:" not in block:
        continue
    size = first_match(block, r"^\s*Size:\s*(.+)$")
    if not size or size.lower().startswith("no module"):
        continue
    dimms.append({
        "size": size,
        "type": first_match(block, r"^\s*Type:\s*(.+)$"),
        "speed": first_match(block, r"^\s*Speed:\s*(.+)$"),
        "configured_speed": first_match(block, r"^\s*Configured Memory Speed:\s*(.+)$"),
        "manufacturer": first_match(block, r"^\s*Manufacturer:\s*(.+)$"),
        "part_number": first_match(block, r"^\s*Part Number:\s*(.+)$"),
        "locator": first_match(block, r"^\s*Locator:\s*(.+)$"),
    })

doc = {
    "captured_at_utc": datetime.now(timezone.utc).isoformat(),
    "hostname": platform.node(),
    "arch": platform.machine(),
    "uname": read("uname"),
    "os_release": read("os_release"),
    "page_size": read("pagesize"),
    "cpu": {
        "model": first_match(lscpu, r"^Model name:\s*(.+)$"),
        "sockets": first_match(lscpu, r"^Socket\(s\):\s*(.+)$"),
        "cores_per_socket": first_match(lscpu, r"^Core\(s\) per socket:\s*(.+)$"),
        "threads_per_core": first_match(lscpu, r"^Thread\(s\) per core:\s*(.+)$"),
        "cpus": first_match(lscpu, r"^CPU\(s\):\s*(.+)$"),
        "max_mhz": first_match(lscpu, r"^CPU max MHz:\s*(.+)$"),
        "min_mhz": first_match(lscpu, r"^CPU min MHz:\s*(.+)$"),
        "mhz": first_match(lscpu, r"^CPU MHz:\s*(.+)$"),
        "numa_nodes": first_match(lscpu, r"^NUMA node\(s\):\s*(.+)$"),
        "l1d": first_match(lscpu, r"^L1d cache:\s*(.+)$"),
        "l1i": first_match(lscpu, r"^L1i cache:\s*(.+)$"),
        "l2": first_match(lscpu, r"^L2 cache:\s*(.+)$"),
        "l3": first_match(lscpu, r"^L3 cache:\s*(.+)$"),
        "vulnerabilities_note": "see raw lscpu text",
        "dmidecode_processor_excerpt": dmi_cpu[:2000],
        "governors": read("governors"),
        "cpufreq_cpu0": read("cpufreq"),
    },
    "memory": {
        "memtotal": first_match(meminfo, r"^MemTotal:\s*(.+)$"),
        "memavailable": first_match(meminfo, r"^MemAvailable:\s*(.+)$"),
        "hugepages": first_match(meminfo, r"^HugePages_Total:\s*(.+)$"),
        "hugepage_size": first_match(meminfo, r"^Hugepagesize:\s*(.+)$"),
        "dimms": dimms,
        "dimm_count": len(dimms),
    },
    "system": {
        "manufacturer": first_match(dmi_sys, r"^\s*Manufacturer:\s*(.+)$"),
        "product_name": first_match(dmi_sys, r"^\s*Product Name:\s*(.+)$"),
        "serial": first_match(dmi_sys, r"^\s*Serial Number:\s*(.+)$"),
        "uuid": first_match(dmi_sys, r"^\s*UUID:\s*(.+)$"),
    },
    "chassis_cooling": {
        "chassis_type": first_match(dmi_chassis, r"^\s*Type:\s*(.+)$"),
        "chassis_manufacturer": first_match(dmi_chassis, r"^\s*Manufacturer:\s*(.+)$"),
        "thermal_zones": read("thermal"),
        "sensors": read("sensors"),
    },
    "storage": {
        "lsblk": read("block"),
        "nvme": read("nvme"),
        "df": read("df"),
    },
    "network": {
        "nic": read("nic"),
        "neigh_sysctl": read("neigh"),
    },
    "virtualization": {
        "kvm": read("kvm"),
        "firecracker": read("firecracker"),
        "fc_count": read("fc_count"),
    },
    "rlp_cell": {
        "units": read("rlp_units"),
        "health": read("rlp_health"),
        "region_target": os.environ.get("TARGET", "epyc9755"),
    },
    "socket_pin": {
        "slice_cpus": Path("/sys/fs/cgroup/rlp.slice/cpuset.cpus").read_text().strip()
        if Path("/sys/fs/cgroup/rlp.slice/cpuset.cpus").exists()
        else None,
        "slice_mems": Path("/sys/fs/cgroup/rlp.slice/cpuset.mems").read_text().strip()
        if Path("/sys/fs/cgroup/rlp.slice/cpuset.mems").exists()
        else None,
        "vms_cpus": Path("/sys/fs/cgroup/rlp.slice/vms/cpuset.cpus").read_text().strip()
        if Path("/sys/fs/cgroup/rlp.slice/vms/cpuset.cpus").exists()
        else None,
        "vms_mems": Path("/sys/fs/cgroup/rlp.slice/vms/cpuset.mems").read_text().strip()
        if Path("/sys/fs/cgroup/rlp.slice/vms/cpuset.mems").exists()
        else None,
        "node0_cpulist": Path("/sys/devices/system/node/node0/cpulist").read_text().strip()
        if Path("/sys/devices/system/node/node0/cpulist").exists()
        else None,
    },
    "raw_sections": {p.stem: p.read_text(errors="replace")[:50000] for p in sorted(raw.glob("*.txt"))},
}

out_json.write_text(json.dumps(doc, indent=2) + "\n")

lines = []
lines.append(f"# Host hardware inventory — {doc['hostname']}")
lines.append("")
lines.append(f"Captured UTC: `{doc['captured_at_utc']}`")
lines.append("")
lines.append("## CPU")
c = doc["cpu"]
for k in ("model", "sockets", "cores_per_socket", "threads_per_core", "cpus", "max_mhz", "min_mhz", "mhz", "numa_nodes", "l3"):
    lines.append(f"- **{k}:** {c.get(k) or '(missing)'}")
lines.append("")
lines.append("## Memory")
m = doc["memory"]
lines.append(f"- **MemTotal:** {m.get('memtotal') or '(missing)'}")
lines.append(f"- **DIMM count:** {m.get('dimm_count')}")
for i, d in enumerate(m.get("dimms") or [], 1):
    lines.append(
        f"- DIMM {i}: {d.get('size')} {d.get('type')} @ {d.get('speed') or d.get('configured_speed')} "
        f"({d.get('manufacturer')} {d.get('part_number')}) locator={d.get('locator')}"
    )
lines.append("")
lines.append("## System / chassis / cooling")
s = doc["system"]
ch = doc["chassis_cooling"]
lines.append(f"- **System:** {s.get('manufacturer')} {s.get('product_name')}")
lines.append(f"- **Chassis type:** {ch.get('chassis_type')}")
lines.append("")
lines.append("```")
lines.append((ch.get("sensors") or "(no lm-sensors output)")[:3000])
lines.append("```")
lines.append("")
lines.append("## Virtualization / cell")
v = doc["virtualization"]
r = doc["rlp_cell"]
lines.append(f"- **KVM:** {(v.get('kvm') or '')[:120]}")
lines.append(f"- **Firecracker:** {(v.get('firecracker') or '')[:120]}")
lines.append(f"- **FC count:** {v.get('fc_count')}")
lines.append(f"- **Units:** {r.get('units')}")
lines.append(f"- **Health:** {r.get('health')}")
lines.append("")
lines.append(f"Full JSON: `{out_json}`")
out_md.write_text("\n".join(lines) + "\n")
print(out_json)
print(out_md)
PY

cp -f "${JSON_OUT}" "${NVIDIA_OUT}/"
cp -f "${MD_OUT}" "${NVIDIA_OUT}/"
log "wrote ${JSON_OUT}"
log "wrote ${MD_OUT}"
log "copied to ${NVIDIA_OUT}/"

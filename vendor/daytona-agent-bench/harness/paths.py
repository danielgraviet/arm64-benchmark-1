"""Default JSONL output paths. The NVIDIA ladder wrapper overrides --output."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def rlp_cpu_series_suffix(
    cpu: float | None,
    cpu_max: float | None = None,
) -> str:
    parts: list[str] = []
    if cpu is not None and abs(float(cpu) - 1.0) >= 1e-9:
        text = f"{float(cpu):.6f}".rstrip("0").rstrip(".")
        parts.append("c" + text.replace(".", "p"))
    if cpu_max is not None:
        text = f"{float(cpu_max):.6f}".rstrip("0").rstrip(".")
        parts.append("max" + text.replace(".", "p"))
    if not parts:
        return ""
    return "-" + "-".join(parts)


def result_series_name(
    runner: str,
    target: str | None = None,
    *,
    host_cpus: int | None = None,
    rlp_cpu: float | None = None,
    rlp_cpu_max: float | None = None,
    numa_node: int | None = None,
    cpuset_mems: str | None = None,
) -> str:
    if runner == "rlp":
        base = "rlp-local"
        return base + rlp_cpu_series_suffix(rlp_cpu, rlp_cpu_max)
    if runner == "docker":
        if numa_node is not None:
            return f"{runner}-numa{numa_node}"
        mem = (cpuset_mems or "").strip()
        mem_s = "-m" + mem.replace(",", "-") if mem else ""
        if host_cpus is not None:
            return f"{runner}-c{host_cpus}{mem_s}"
        if mem_s:
            return f"{runner}{mem_s}"
    return runner


def default_output_path(
    runner: str,
    n: int,
    *,
    benchmark: str = "agent",
    target: str | None = None,
    host_cpus: int | None = None,
    rlp_cpu: float | None = None,
    rlp_cpu_max: float | None = None,
    numa_node: int | None = None,
    cpuset_mems: str | None = None,
) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    series = result_series_name(
        runner,
        target,
        host_cpus=host_cpus,
        rlp_cpu=rlp_cpu,
        rlp_cpu_max=rlp_cpu_max,
        numa_node=numa_node,
        cpuset_mems=cpuset_mems,
    )
    base = ROOT / "data" / benchmark / series
    return base / f"concurrency_{stamp}_n{n}.jsonl"

"""Default JSONL output paths under data/<benchmark>/<series>/."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from harness.regions import ARM64_TARGETS, DAYTONA_GRAVITON5_TARGET

ROOT = Path(__file__).resolve().parent.parent


def rlp_cpu_series_suffix(cpu: float | None) -> str:
    """``-c0p125`` when create CPU is not 1.0, else empty (keep 1-vCPU series)."""
    if cpu is None or abs(float(cpu) - 1.0) < 1e-9:
        return ""
    text = f"{float(cpu):.6f}".rstrip("0").rstrip(".")
    return "-c" + text.replace(".", "p")


def result_series_name(
    runner: str,
    target: str | None = None,
    *,
    host_cpus: int | None = None,
    rlp_cpu: float | None = None,
    numa_node: int | None = None,
    cpuset_mems: str | None = None,
) -> str:
    """Map CLI runner (+ optional RLP target / Docker CPU cap) to a results folder.

    RLP default-region, ARM64, Phoenix (Turin), and onsite Vera runs are split
    so EDA can chart them as separate series (``rlp-x86`` vs ``rlp-arm64`` vs
    ``rlp-phoenix`` vs ``rlp-vera``). Fractional ``--rlp-cpu`` appends
    ``-c0p125`` so 0.125-CPU density ladders do not steal the 1-vCPU series.

    Daytona ``--target us-east-1-arm`` (Graviton5) writes to ``daytona-graviton5``
    so it stays separate from default-target ``daytona`` (x86).

    Docker with ``--host-cpus N`` writes to ``docker-cN`` so capped runs stay
    separate from full-machine ``docker`` results. ``--numa-node N`` writes
    ``docker-numaN`` (CPU+memory pinned to that node).
    """
    if runner == "rlp":
        if target == "vera":
            base = "rlp-vera"
        elif target == "us-phoenix-1":
            base = "rlp-phoenix"
        elif target and target in ARM64_TARGETS:
            base = "rlp-arm64"
        else:
            base = "rlp-x86"
        return base + rlp_cpu_series_suffix(rlp_cpu)
    # Graviton5 target is linux-vm–only today.
    # Cold VM → daytona-graviton5; hot/memory snap → daytona-graviton5-hot.
    if target == DAYTONA_GRAVITON5_TARGET:
        if runner == "daytona-vm-hot":
            return "daytona-graviton5-hot"
        if runner in ("daytona", "daytona-vm"):
            return "daytona-graviton5"
    if runner in ("docker", "ec2"):
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
    numa_node: int | None = None,
    cpuset_mems: str | None = None,
) -> Path:
    """Path like ``data/analytics/rlp-arm64/concurrency_<ts>_n10.jsonl``."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    series = result_series_name(
        runner,
        target,
        host_cpus=host_cpus,
        rlp_cpu=rlp_cpu,
        numa_node=numa_node,
        cpuset_mems=cpuset_mems,
    )
    base = ROOT / "data" / benchmark / series
    return base / f"concurrency_{stamp}_n{n}.jsonl"

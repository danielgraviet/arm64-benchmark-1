"""Default JSONL output paths under data/<benchmark>/<series>/."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from harness.regions import ARM64_TARGETS

ROOT = Path(__file__).resolve().parent.parent


def result_series_name(
    runner: str,
    target: str | None = None,
    *,
    host_cpus: int | None = None,
) -> str:
    """Map CLI runner (+ optional RLP target / Docker CPU cap) to a results folder.

    RLP default-region, ARM64, and onsite Vera runs are split so EDA can chart
    them as separate series (``rlp-x86`` vs ``rlp-arm64`` vs ``rlp-vera``).

    Docker with ``--host-cpus N`` writes to ``docker-cN`` so capped runs stay
    separate from full-machine ``docker`` results.
    """
    if runner == "rlp":
        if target == "vera":
            return "rlp-vera"
        if target and target in ARM64_TARGETS:
            return "rlp-arm64"
        return "rlp-x86"
    if runner in ("docker", "ec2") and host_cpus is not None:
        return f"{runner}-c{host_cpus}"
    return runner


def default_output_path(
    runner: str,
    n: int,
    *,
    benchmark: str = "agent",
    target: str | None = None,
    host_cpus: int | None = None,
) -> Path:
    """Path like ``data/analytics/rlp-arm64/concurrency_<ts>_n10.jsonl``."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    series = result_series_name(runner, target, host_cpus=host_cpus)
    base = ROOT / "data" / benchmark / series
    return base / f"concurrency_{stamp}_n{n}.jsonl"

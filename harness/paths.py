"""Default JSONL output paths under data/<benchmark>/<series>/."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from harness.regions import ARM64_TARGETS

ROOT = Path(__file__).resolve().parent.parent


def result_series_name(runner: str, target: str | None = None) -> str:
    """Map CLI runner (+ optional RLP target) to a results folder name.

    RLP default-region and ARM64 runs are split so EDA can chart them as
    separate series (``rlp-x86`` vs ``rlp-arm64``).
    """
    if runner == "rlp":
        if target and target in ARM64_TARGETS:
            return "rlp-arm64"
        return "rlp-x86"
    return runner


def default_output_path(
    runner: str,
    n: int,
    *,
    benchmark: str = "agent",
    target: str | None = None,
) -> Path:
    """Path like ``data/analytics/rlp-arm64/concurrency_<ts>_n10.jsonl``."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    series = result_series_name(runner, target)
    base = ROOT / "data" / benchmark / series
    return base / f"concurrency_{stamp}_n{n}.jsonl"

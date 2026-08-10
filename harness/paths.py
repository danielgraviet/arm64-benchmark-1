"""Default JSONL output paths under data/<benchmark>/<runner>/[target/]."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def default_output_path(
    runner: str,
    n: int,
    *,
    benchmark: str = "agent",
    target: str | None = None,
) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    base = ROOT / "data" / benchmark / runner
    if target:
        base = base / target
    return base / f"concurrency_{stamp}_n{n}.jsonl"

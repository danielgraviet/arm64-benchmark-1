"""Default JSONL output paths under data/<runner>/."""

from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def default_output_path(runner: str, n: int) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    return ROOT / "data" / runner / f"concurrency_{stamp}_n{n}.jsonl"

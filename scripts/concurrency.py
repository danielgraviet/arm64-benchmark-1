"""Deprecated. Use: uv run main.py --runner docker --levels ... --n ..."""

from __future__ import annotations

import sys

print(
    "scripts/concurrency.py is deprecated.\n"
    "Use: uv run main.py --runner docker --levels 1 8 22 44 88 176 --n 20",
    file=sys.stderr,
)
raise SystemExit(2)

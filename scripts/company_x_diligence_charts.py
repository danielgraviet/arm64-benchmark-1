"""Charts for docs/company-x-compute-diligence.md (base 1 GiB ladder through c=704).

Same styling as nvidia-agent-brief agent charts, but no max-pack extension —
both Vera and Zen 5 stop at concurrency 704.

Usage:
  uv run python scripts/company_x_diligence_charts.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from scripts.nvidia_brief_agent_charts import (  # noqa: E402
    BASE,
    SERIES,
    SPLIT_AT,
    merge_ladders,
    plot_duration,
    plot_throughput,
)

OUT = ROOT / "docs"
MAX_CONCURRENCY = SPLIT_AT  # 704


def load_base_only() -> dict[str, tuple[list[dict], list[dict]]]:
    loaded: dict[str, tuple[list[dict], list[dict]]] = {}
    for key, base_path in BASE.items():
        runs, summaries = merge_ladders(base_path, None, extend_from=MAX_CONCURRENCY + 1)
        summaries = [s for s in summaries if int(s["concurrency"]) <= MAX_CONCURRENCY]
        runs = [r for r in runs if int(r["concurrency"]) <= MAX_CONCURRENCY]
        loaded[key] = (runs, summaries)
        levels = [int(s["concurrency"]) for s in summaries]
        print(f"{key}: {len(levels)} levels (max c={max(levels)})")
    return loaded


def main() -> None:
    loaded = load_base_only()
    OUT.mkdir(parents=True, exist_ok=True)
    plot_throughput(loaded, OUT)
    plot_duration(loaded, OUT)
    print(f"Wrote charts to {OUT}/")
    for name in ("throughput_vs_concurrency.png", "duration_vs_concurrency.png"):
        print(f"  - {name}")


if __name__ == "__main__":
    main()

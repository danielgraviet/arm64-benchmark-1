"""Charts for nvidia-agent-brief-maxpack/. Vera vs Phoenix 9J45 vs Zen 5 9575.

Base burst ladder (1 GiB, c=44..704) merged with max-pack through c=2000.
Vera and Phoenix: 0.125 vCPU / 512 MiB. Redswitches: 0.025 vCPU / 100 MiB.

Usage:
  uv run python scripts/nvidia_brief_maxpack_charts.py            # all three chips
  uv run python scripts/nvidia_brief_maxpack_charts.py --no-9575  # hide 9575 on PNGs
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from eda import completed_throughput, load_jsonl  # noqa: E402
from scripts.nvidia_brief_agent_charts import (  # noqa: E402
    SPLIT_AT,
    merge_ladders,
    p50_duration_ms,
)

OUT = ROOT / "nvidia-agent-brief-maxpack"

CHART_MIN_C = 44
CHART_MAX_C = 2000
VERA_C2000_SOURCE = 2112  # internal pin only; plotted as 2000

BASE: dict[str, Path] = {
    "vera": ROOT
    / "data/agent/rlp-vera-c0p125-max1/concurrency_20260826_005637_n50.jsonl",
    "phoenix": ROOT
    / "data/agent/rlp-phoenix-c0p125-max1/concurrency_20260901_115935_n50.jsonl",
    "redswitches": ROOT
    / "data/agent/rlp-redswitches-c0p125-max1/concurrency_20260828_183551_n50.jsonl",
}

MAXPACK: dict[str, Path] = {
    "vera": ROOT
    / "data/agent/rlp-vera-c0p125-max1-m512/concurrency_20260826_230252_n50.jsonl",
    "phoenix": ROOT
    / "data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_20260901_104841_n50.jsonl",
    "redswitches": ROOT
    / "data/agent/rlp-redswitches-c0p025-max1-m100/concurrency_20260828_225238_n50.jsonl",
}

# Matched 512 MiB 704+880. Replaces 1 GiB 704 and the too-fast 880 from MAXPACK.
PHOENIX_GLUE = (
    ROOT
    / "data/agent/rlp-phoenix-c0p125-max1-m512/concurrency_20260901_125904_n50.jsonl"
)
PHOENIX_GLUE_LEVELS = frozenset({704, 880})

SERIES: list[tuple[str, str, str]] = [
    ("vera", "Vera", "#76B900"),
    ("phoenix", "Zen 5 (9J45)", "#7D7D7D"),
    ("redswitches", "Zen 5 (9575)", "#C41E3A"),
]

GROUND_TRUTH: dict[str, Path] = {
    "vera": OUT / "vera.jsonl",
    "phoenix": OUT / "zen5-9j45.jsonl",
    "redswitches": OUT / "zen5-9575.jsonl",
}

def duration_note(include_9575: bool) -> str:
    extra = (
        " 9575 uses 0.025 / 100 MiB packing knobs."
        if include_9575
        else ""
    )
    return (
        "p50 duration_ms is in-sandbox work only (excludes create/delete and client RTT). "
        "Vera and 9J45 use 0.125 vCPU / 512 MiB from 880."
        + extra
        + " Burst caps match (1 vCPU, 4 GB RAM)."
    )


def tput_note(include_9575: bool) -> str:
    extra = (
        " 9575 uses 0.025 / 100 MiB packing knobs."
        if include_9575
        else ""
    )
    return (
        "Throughput = completed runs / exec wall. "
        "Vera and 9J45 use 0.125 vCPU / 512 MiB from 880."
        + extra
        + " Burst caps match (1 vCPU, 4 GB RAM)."
    )


def chart_pair_title(include_9575: bool) -> str:
    if include_9575:
        return "Agent task — Vera versus Zen 5 (9J45) versus Zen 5 (9575)"
    return "Agent task — Vera versus Zen 5 (9J45)"


def merge_base_maxpack(base: Path, extend: Path | None) -> tuple[list[dict], list[dict]]:
    ext = extend if extend is not None and extend.is_file() else None
    return merge_ladders(base, ext, extend_from=SPLIT_AT + 1)


def overlay_levels(
    runs: list[dict],
    summaries: list[dict],
    overlay: Path,
    levels: frozenset[int],
) -> tuple[list[dict], list[dict]]:
    """Replace listed rungs with rows from ``overlay`` (same memory pack as max-pack)."""
    _, ov_runs, ov_summaries = load_jsonl(overlay)
    for summary in ov_summaries:
        level = int(summary["concurrency"])
        if level not in levels:
            continue
        summaries = [s for s in summaries if int(s["concurrency"]) != level]
        runs = [r for r in runs if int(r["concurrency"]) != level]
        summaries.append(summary)
        runs.extend(r for r in ov_runs if int(r["concurrency"]) == level)
    summaries.sort(key=lambda s: int(s["concurrency"]))
    return runs, summaries


def write_ground_truth_jsonl(
    path: Path,
    *,
    series_key: str,
    label: str,
    base: Path,
    extend: Path | None,
    runs: list[dict],
    summaries: list[dict],
    source_glue: Path | None = None,
    glue_levels: frozenset[int] | None = None,
) -> None:
    """One JSONL per chip: merged 1 GiB base (c<705) + max-pack (c>=705)."""
    meta_base, _, _ = load_jsonl(base)
    meta_ext = None
    if extend is not None and extend.is_file():
        meta_ext, _, _ = load_jsonl(extend)
    meta = dict(meta_ext or meta_base or {"type": "meta"})
    meta["type"] = "meta"
    meta["brief_series"] = series_key
    meta["brief_label"] = label
    meta["source_base"] = str(base.relative_to(ROOT))
    meta["source_maxpack"] = (
        str(extend.relative_to(ROOT)) if extend is not None and extend.is_file() else None
    )
    if source_glue is not None and source_glue.is_file():
        meta["source_glue"] = str(source_glue.relative_to(ROOT))
        meta["source_glue_levels"] = sorted(glue_levels or [])
    by_c: dict[int, list[dict]] = {}
    for row in runs:
        by_c.setdefault(int(row["concurrency"]), []).append(row)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        fh.write(json.dumps(meta) + "\n")
        for summary in summaries:
            level = int(summary["concurrency"])
            for row in by_c.get(level, []):
                fh.write(json.dumps(row) + "\n")
            fh.write(json.dumps(summary) + "\n")
    print(f"  ground truth {path.name} levels={[int(s['concurrency']) for s in summaries]}")


def trim_c_range(
    runs: list[dict], summaries: list[dict]
) -> tuple[list[dict], list[dict]]:
    summaries = [
        s
        for s in summaries
        if CHART_MIN_C <= int(s["concurrency"]) <= CHART_MAX_C
    ]
    levels = {int(s["concurrency"]) for s in summaries}
    runs = [r for r in runs if int(r["concurrency"]) in levels]
    summaries.sort(key=lambda s: int(s["concurrency"]))
    return runs, summaries


def align_vera_to_matched_ladder(
    runs: list[dict], summaries: list[dict]
) -> tuple[list[dict], list[dict]]:
    """Drop Vera rungs above 2000; plot c=2112 data at c=2000."""
    src_summary = next(
        (s for s in summaries if int(s["concurrency"]) == VERA_C2000_SOURCE), None
    )
    if src_summary is None:
        raise SystemExit(
            f"Vera max-pack missing c={VERA_C2000_SOURCE} — cannot map to c=2000"
        )
    src_runs = [r for r in runs if int(r["concurrency"]) == VERA_C2000_SOURCE]

    summaries = [
        s
        for s in summaries
        if int(s["concurrency"]) <= CHART_MAX_C
        and int(s["concurrency"]) != VERA_C2000_SOURCE
    ]
    at_2000 = copy.deepcopy(src_summary)
    at_2000["concurrency"] = CHART_MAX_C
    summaries.append(at_2000)
    summaries.sort(key=lambda s: int(s["concurrency"]))

    runs = [
        r
        for r in runs
        if int(r["concurrency"]) <= CHART_MAX_C
        and int(r["concurrency"]) != VERA_C2000_SOURCE
    ]
    for r in src_runs:
        remapped = copy.deepcopy(r)
        remapped["concurrency"] = CHART_MAX_C
        runs.append(remapped)

    return runs, summaries


def load_series() -> dict[str, tuple[list[dict], list[dict]]]:
    loaded: dict[str, tuple[list[dict], list[dict]]] = {}
    for key in SERIES:
        series_key = key[0]
        base_path = BASE[series_key]
        ext_path = MAXPACK.get(series_key)
        if not base_path.is_file():
            print(f"SKIP {series_key}: missing base {base_path.relative_to(ROOT)}")
            continue
        runs, summaries = merge_base_maxpack(base_path, ext_path)
        glue_path = PHOENIX_GLUE if series_key == "phoenix" else None
        if glue_path is not None:
            if not glue_path.is_file():
                raise SystemExit(f"Missing Phoenix glue file {glue_path}")
            runs, summaries = overlay_levels(
                runs, summaries, glue_path, PHOENIX_GLUE_LEVELS
            )
        summaries_gt = [
            s for s in summaries if int(s["concurrency"]) >= CHART_MIN_C
        ]
        runs_gt = [r for r in runs if int(r["concurrency"]) >= CHART_MIN_C]
        write_ground_truth_jsonl(
            GROUND_TRUTH[series_key],
            series_key=series_key,
            label=next(lab for k, lab, _ in SERIES if k == series_key),
            base=base_path,
            extend=ext_path,
            runs=runs_gt,
            summaries=summaries_gt,
            source_glue=glue_path,
            glue_levels=PHOENIX_GLUE_LEVELS if glue_path is not None else None,
        )
        if series_key == "vera":
            runs, summaries = align_vera_to_matched_ladder(runs, summaries)
        runs, summaries = trim_c_range(runs, summaries)
        loaded[series_key] = (runs, summaries)
        level_list = [int(s["concurrency"]) for s in summaries]
        fails = sum(int(s.get("failures", 0)) for s in summaries)
        print(
            f"{series_key}: {len(level_list)} levels "
            f"(c={level_list[0]}..{level_list[-1]}) failures={fails}"
        )
    return loaded


def all_levels(loaded: dict[str, tuple[list[dict], list[dict]]]) -> list[int]:
    ladders = {
        key: [int(s["concurrency"]) for s in summaries]
        for key, (_, summaries) in loaded.items()
    }
    first = next(iter(ladders.values()))
    for key, levels in ladders.items():
        if levels != first:
            print(f"WARN ladder mismatch {key}={levels} vs {first}")
    union: set[int] = set()
    for levels in ladders.values():
        union.update(levels)
    return sorted(union)


def plot_throughput(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out_dir: Path,
    *,
    include_9575: bool,
) -> None:
    labels = {k: lab for k, lab, _ in SERIES}
    colors = {k: col for k, _, col in SERIES}
    fig, ax = plt.subplots(figsize=(13, 5.5))

    for key, (_, summaries) in loaded.items():
        levels = [int(s["concurrency"]) for s in summaries]
        tput = [completed_throughput(s, series=key) for s in summaries]
        ax.plot(
            levels,
            tput,
            marker="o",
            linewidth=2.2,
            label=labels[key],
            color=colors[key],
        )
        for level, value in zip(levels, tput):
            ax.annotate(
                f"{value:.1f}",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=7,
            )

    levels = all_levels(loaded)
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("Throughput (completed runs / sec)")
    ax.set_title(
        f"{chart_pair_title(include_9575)}\n"
        "Throughput vs concurrency (higher is better)",
        fontsize=13,
    )
    ax.set_xticks(levels)
    ax.set_xticklabels([str(level) for level in levels], rotation=45, ha="right")
    ax.legend(loc="upper left", frameon=False, fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, tput_note(include_9575), ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.22)
    fig.savefig(out_dir / "throughput_vs_concurrency.png", dpi=180)
    plt.close(fig)


def plot_duration(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out_dir: Path,
    *,
    include_9575: bool,
) -> None:
    labels = {k: lab for k, lab, _ in SERIES}
    colors = {k: col for k, _, col in SERIES}
    fig, ax = plt.subplots(figsize=(13, 5.5))

    for key, (runs, summaries) in loaded.items():
        levels: list[int] = []
        durs: list[float] = []
        for s in summaries:
            dur = p50_duration_ms(runs, s)
            if not dur:
                continue
            levels.append(int(s["concurrency"]))
            durs.append(dur)
        ax.plot(
            levels,
            durs,
            marker="o",
            linewidth=2.2,
            label=labels[key],
            color=colors[key],
        )
        for level, value in zip(levels, durs):
            ax.annotate(
                f"{value:.0f}",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=7,
            )

    levels = all_levels(loaded)
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("p50 duration_ms (in-sandbox work)")
    ax.set_title(
        f"{chart_pair_title(include_9575)}\n"
        "In-sandbox p50 duration vs concurrency (lower is better)",
        fontsize=13,
    )
    ax.set_xticks(levels)
    ax.set_xticklabels([str(level) for level in levels], rotation=45, ha="right")
    ax.legend(loc="upper left", frameon=False, fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, duration_note(include_9575), ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.22)
    fig.savefig(out_dir / "duration_vs_concurrency.png", dpi=180)
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Max-pack charts. --no-9575 hides 9575 on PNGs only."
    )
    parser.add_argument(
        "--no-9575",
        action="store_true",
        help="Omit Zen 5 (9575) from the PNGs. Still writes zen5-9575.jsonl.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    loaded = load_series()
    if len(loaded) != 3:
        raise SystemExit(
            "Expected vera + phoenix + redswitches. Check BASE/MAXPACK paths."
        )
    include_9575 = not args.no_9575
    plotted = loaded if include_9575 else {
        k: v for k, v in loaded.items() if k != "redswitches"
    }
    OUT.mkdir(parents=True, exist_ok=True)
    plot_throughput(plotted, OUT, include_9575=include_9575)
    plot_duration(plotted, OUT, include_9575=include_9575)
    print(f"Wrote charts to {OUT}/ (9575 {'on' if include_9575 else 'off'})")
    for name in ("throughput_vs_concurrency.png", "duration_vs_concurrency.png"):
        print(f"  - {name}")
    for path in GROUND_TRUTH.values():
        print(f"  - {path.name}")


if __name__ == "__main__":
    main()

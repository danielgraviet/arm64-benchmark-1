"""Explore concurrency JSONL results across runners / RLP arch series.

Picks the newest ``data/<benchmark>/<series>/concurrency_*.jsonl`` per series
(e.g. ``rlp-phoenix``, ``rlp-vera``), prints a metrics table, and writes charts
to ``eda_output/<benchmark>/``.

Use ``--include`` to chart only named series. Benchmark folders under ``data/``
are discovered dynamically.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
OUT_DIR = ROOT / "eda_output"

# Preferred chart/table order; any other series dirs are appended.
SERIES_ORDER = (
    "docker",
    "docker-c32",
    "docker-numa0",
    "daytona",
    "daytona-graviton5",
    "daytona-graviton5-hot",
    "daytona-vm",
    "daytona-vm-hot",
    "e2b",
    "rlp-x86",
    "rlp-phoenix",
    "rlp-phoenix-c0p125",
    "rlp-arm64",
    "rlp-vera",
    "rlp-vera-c0p125",
    "rlp-vera-c0p125-max1",
    "rlp",  # legacy folder name (pre split)
    "ec2",
)
SERIES_COLORS = {
    "docker": "#4C78A8",  # blue
    "docker-c32": "#1F4E79",  # darker blue — 32-core cap parity
    "docker-numa0": "#5B8FA8",  # NUMA-pinned Docker
    "daytona": "#2CA02C",  # green
    "daytona-graviton5": "#98DF8A",  # light green — Graviton5 cold VM
    "daytona-graviton5-hot": "#2E7D32",  # darker green — Graviton5 hot/memory snap
    "daytona-vm": "#17BECF",  # cyan — Linux VM cold boot
    "daytona-vm-hot": "#D62728",  # red — Linux VM hot/memory snap
    "e2b": "#9467BD",  # purple
    "rlp-x86": "#FF7F0E",  # orange
    "rlp": "#FF7F0E",  # legacy → same as x86
    "rlp-phoenix": "#7D7D7D",  # gray — OCI Phoenix / Zen 5 Turin
    "rlp-phoenix-c0p125": "#8A6D00",  # darker gold — 0.125 CPU density
    "rlp-arm64": "#D62728",  # red
    "rlp-vera": "#76B900",  # NVIDIA green — onsite Vera RLP cell
    "rlp-vera-c0p125": "#C45C7A",  # lighter crimson — 0.125 CPU density
    "rlp-vera-c0p125-max1": "#4CAF50",  # burst 0.125/max1
    "ec2": "#8C564B",  # brown
}

LATENCY_NOTE = (
    "Cloud latency = create + exec (+ delete outside stamp); "
    "duration_ms = in-container work only (Chart A chip metric)"
)
DURATION_NOTE = (
    "duration_ms is in-sandbox CPU/IO; compare this for chip claims, not wall latency_ms"
)


def series_color(series: str) -> str:
    return SERIES_COLORS.get(series, "#7F7F7F")


def list_benchmark_dirs() -> list[str]:
    """Return data/<name>/ directories (agent, analytics, rl, …)."""
    if not DATA_DIR.is_dir():
        return []
    return sorted(p.name for p in DATA_DIR.iterdir() if p.is_dir() and not p.name.startswith("."))


def list_series_dirs(benchmark: str) -> list[str]:
    """Result series under data/<benchmark>/ that contain concurrency_*.jsonl."""
    root = DATA_DIR / benchmark
    if not root.is_dir():
        return []
    found: list[str] = []
    for path in sorted(root.iterdir()):
        if not path.is_dir() or path.name.startswith("."):
            continue
        if any(path.glob("concurrency_*.jsonl")) or any(
            path.glob("*/concurrency_*.jsonl")
        ):
            found.append(path.name)
    # Stable preferred order, then leftovers.
    ordered = [name for name in SERIES_ORDER if name in found]
    ordered.extend(name for name in found if name not in ordered)
    return ordered


def latest_jsonl(benchmark: str, series: str) -> Path | None:
    """Newest concurrency_*.jsonl under data/<benchmark>/<series>/."""
    base = DATA_DIR / benchmark / series
    if not base.is_dir():
        return None
    paths = list(base.glob("concurrency_*.jsonl"))
    paths.extend(base.glob("*/concurrency_*.jsonl"))
    if not paths:
        return None
    return sorted(paths)[-1]


def discover_datasets(benchmark: str) -> dict[str, Path]:
    found: dict[str, Path] = {}
    for series in list_series_dirs(benchmark):
        path = latest_jsonl(benchmark, series)
        if path is not None:
            found[series] = path
    if not found:
        raise FileNotFoundError(
            f"No concurrency_*.jsonl files under {DATA_DIR}/{benchmark}/"
        )
    return found


def load_jsonl(path: Path) -> tuple[dict | None, list[dict], list[dict]]:
    meta: dict | None = None
    runs: list[dict] = []
    summaries: list[dict] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row["type"] == "meta":
                meta = row
            elif row["type"] == "run":
                runs.append(row)
            elif row["type"] == "summary":
                summaries.append(row)
    summaries.sort(key=lambda r: r["concurrency"])
    return meta, runs, summaries


def mean_latency(runs: list[dict], concurrency: int) -> float:
    values = [
        float(r["latency_ms"])
        for r in runs
        if r.get("concurrency") == concurrency and "latency_ms" in r
    ]
    return float(np.mean(values)) if values else 0.0


def mean_duration(runs: list[dict], concurrency: int) -> float:
    values = [
        float(r["duration_ms"])
        for r in runs
        if r.get("concurrency") == concurrency and r.get("duration_ms") is not None
    ]
    return float(np.mean(values)) if values else 0.0


def percentile_duration(runs: list[dict], concurrency: int, pct: float) -> float:
    values = [
        float(r["duration_ms"])
        for r in runs
        if r.get("concurrency") == concurrency and r.get("duration_ms") is not None
    ]
    if not values:
        return 0.0
    ordered = sorted(values)
    k = (len(ordered) - 1) * (pct / 100)
    f = int(k)
    c = min(f + 1, len(ordered) - 1)
    if f == c:
        return float(ordered[f])
    return float(ordered[f] + (ordered[c] - ordered[f]) * (k - f))


def all_levels(loaded: dict[str, tuple[list[dict], list[dict]]]) -> list[int]:
    return sorted(
        {s["concurrency"] for _, summaries in loaded.values() for s in summaries}
    )


def format_env_line(meta: dict | None) -> str | None:
    if not meta:
        return None
    env = meta.get("env")
    if not isinstance(env, dict):
        return None
    parts = [
        f"arch={env.get('arch')!r}",
        f"cpu_model={env.get('cpu_model')!r}",
        f"host_cpu={env.get('host_cpu')!r}",
        f"probe={env.get('probe')!r}",
    ]
    return "  env: " + " ".join(parts)


def print_summary_table(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    sources: dict[str, Path],
    metas: dict[str, dict | None] | None = None,
) -> None:
    print(LATENCY_NOTE)
    print()
    metas = metas or {}
    for series, path in sources.items():
        print(f"{series}: {path.relative_to(ROOT)}")
        env_line = format_env_line(metas.get(series))
        if env_line:
            print(env_line)
    print()

    header = (
        f"{'series':<16} {'conc':>5} {'p50_ms':>10} {'mean_ms':>10} "
        f"{'p50_dur':>10} {'p99_ms':>10} {'tput/s':>8} "
        f"{'fail':>5} {'runners':>7} {'checksum':>8}"
    )
    print(header)
    print("-" * len(header))

    for series, (runs, summaries) in loaded.items():
        for s in summaries:
            level = s["concurrency"]
            mean_ms = mean_latency(runs, level)
            p50_dur = s.get("p50_duration_ms")
            if p50_dur is None:
                p50_dur = percentile_duration(runs, level, 50)
            runners = s.get("distinct_runners")
            runners_s = f"{int(runners):7d}" if runners is not None else f"{'-':>7}"
            print(
                f"{series:<16} {level:5d} "
                f"{s['p50_ms']:10.1f} {mean_ms:10.1f} "
                f"{float(p50_dur):10.1f} {s['p99_ms']:10.1f} "
                f"{s['throughput_per_sec']:8.2f} "
                f"{s['failures']:5d} {runners_s} {str(s.get('checksum_ok')):>8}"
            )
        print()


def plot_grouped_metric(
    loaded: dict[str, tuple[list[dict], list[dict]]],
    out: Path,
    *,
    metric_key: str | None,
    title: str,
    ylabel: str,
    filename: str,
    from_runs_mean: bool = False,
    from_runs_mean_duration: bool = False,
    footnote: str = LATENCY_NOTE,
) -> None:
    series_list = list(loaded.keys())
    levels = all_levels(loaded)
    x = np.arange(len(levels))
    width = min(0.8 / max(len(series_list), 1), 0.22)

    fig, ax = plt.subplots(figsize=(12, 5))
    for i, series in enumerate(series_list):
        runs, summaries = loaded[series]
        if from_runs_mean_duration:
            values = [mean_duration(runs, level) for level in levels]
        elif from_runs_mean:
            values = [mean_latency(runs, level) for level in levels]
        else:
            by_level = {s["concurrency"]: s[metric_key] for s in summaries}
            values = [by_level.get(level, 0) for level in levels]
        offset = (i - (len(series_list) - 1) / 2) * width
        bars = ax.bar(
            x + offset, values, width, label=series, color=series_color(series)
        )
        ax.bar_label(bars, fmt="%.0f", padding=2, fontsize=7)

    ax.set_xticks(x, [str(level) for level in levels])
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.text(0.5, 0.01, footnote, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / filename, dpi=150)
    plt.close(fig)


def plot_throughput(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    fig, ax = plt.subplots(figsize=(9, 5))
    for series, (_, summaries) in loaded.items():
        levels = [s["concurrency"] for s in summaries]
        tput = [s["throughput_per_sec"] for s in summaries]
        ax.plot(
            levels,
            tput,
            marker="o",
            linewidth=2,
            label=series,
            color=series_color(series),
        )
        for level, value in zip(levels, tput):
            ax.annotate(
                f"{value:.2f}",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=8,
            )

    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("Throughput (runs / sec)")
    ax.set_title("Throughput vs concurrency")
    ax.set_xticks(all_levels(loaded))
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, LATENCY_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "throughput_vs_concurrency.png", dpi=150)
    plt.close(fig)


def plot_duration_line(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    """Line chart of p50 duration_ms vs concurrency (chip only; no create/network)."""
    fig, ax = plt.subplots(figsize=(9, 5))
    plotted = False
    for series, (runs, summaries) in loaded.items():
        levels: list[int] = []
        durs: list[float] = []
        for s in summaries:
            dur = s.get("p50_duration_ms")
            if dur is None:
                dur = percentile_duration(runs, s["concurrency"], 50)
            if not dur:
                continue
            levels.append(s["concurrency"])
            durs.append(float(dur))
        if not levels:
            continue
        plotted = True
        ax.plot(
            levels,
            durs,
            marker="o",
            linewidth=2,
            label=series,
            color=series_color(series),
        )
        for level, value in zip(levels, durs):
            ax.annotate(
                f"{value:.0f}",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=8,
            )

    if not plotted:
        plt.close(fig)
        return

    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("p50 duration_ms (in-sandbox work)")
    ax.set_title("Duration vs concurrency (excludes create / network / toolbox)")
    ax.set_xticks(all_levels(loaded))
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.text(0.5, 0.01, DURATION_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "duration_vs_concurrency.png", dpi=150)
    plt.close(fig)


def plot_chip_speed_vs_concurrency(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    """Marketing line chart: idle chip = 100%. Vera stays high when packing holds.

    Uses p50 duration_ms only (no create / toolbox / network). Each series is
    normalized to its own concurrency=1 so a faster idle chip does not sit
    above a flatter packer.
    """
    fig, ax = plt.subplots(figsize=(9, 5))
    plotted = False
    for series, (runs, summaries) in loaded.items():
        idle = None
        for s in summaries:
            if s["concurrency"] != 1:
                continue
            idle = s.get("p50_duration_ms")
            if idle is None:
                idle = percentile_duration(runs, 1, 50)
            break
        if not idle:
            continue
        idle = float(idle)
        levels: list[int] = []
        pcts: list[float] = []
        for s in summaries:
            dur = s.get("p50_duration_ms")
            if dur is None:
                dur = percentile_duration(runs, s["concurrency"], 50)
            if not dur:
                continue
            levels.append(s["concurrency"])
            pcts.append(100.0 * idle / float(dur))
        if not levels:
            continue
        plotted = True
        ax.plot(
            levels,
            pcts,
            marker="o",
            linewidth=2,
            label=series,
            color=series_color(series),
        )
        for level, value in zip(levels, pcts):
            ax.annotate(
                f"{value:.0f}%",
                (level, value),
                textcoords="offset points",
                xytext=(0, 8),
                ha="center",
                fontsize=8,
            )

    if not plotted:
        plt.close(fig)
        return

    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("In-sandbox chip speed vs idle (%)")
    ax.set_title("Chip speed vs concurrency (100% = idle duration_ms)")
    ax.set_xticks(all_levels(loaded))
    ax.set_ylim(0, None)
    ax.legend()
    ax.grid(True, alpha=0.3)
    fig.text(
        0.5,
        0.01,
        DURATION_NOTE + " · 100% is each series' own c=1 p50 (create tax excluded)",
        ha="center",
        fontsize=8,
        style="italic",
    )
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "chip_speed_vs_concurrency.png", dpi=150)
    plt.close(fig)


def plot_duration_vs_concurrency(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    """Chart A helper: in-container duration_ms p50 beside wall latency p50."""
    series_list = list(loaded.keys())
    levels = all_levels(loaded)
    x = np.arange(len(levels))
    width = min(0.8 / max(len(series_list), 1), 0.22)

    fig, ax = plt.subplots(figsize=(12, 5))
    for i, series in enumerate(series_list):
        runs, summaries = loaded[series]
        by_summary = {s["concurrency"]: s for s in summaries}
        values = []
        for level in levels:
            s = by_summary.get(level, {})
            dur = s.get("p50_duration_ms")
            if dur is None:
                dur = percentile_duration(runs, level, 50)
            values.append(float(dur or 0))
        offset = (i - (len(series_list) - 1) / 2) * width
        bars = ax.bar(
            x + offset, values, width, label=series, color=series_color(series)
        )
        ax.bar_label(bars, fmt="%.0f", padding=2, fontsize=7)

    ax.set_xticks(x, [str(level) for level in levels])
    ax.set_xlabel("Concurrency level")
    ax.set_ylabel("p50 duration_ms")
    ax.set_title("In-container duration_ms vs concurrency (Chart A chip metric)")
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    fig.text(0.5, 0.01, DURATION_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "p50_duration_bars.png", dpi=150)
    plt.close(fig)


def plot_duration_boxplots(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    levels = all_levels(loaded)
    series_list = list(loaded.keys())
    has_duration = any(
        r.get("duration_ms") is not None
        for runs, _ in loaded.values()
        for r in runs
    )
    if not has_duration:
        return

    fig, axes = plt.subplots(
        1, len(series_list), figsize=(4.5 * len(series_list), 5), sharey=True
    )
    if len(series_list) == 1:
        axes = [axes]

    for ax, series in zip(axes, series_list):
        runs, _ = loaded[series]
        by_level: dict[int, list[float]] = defaultdict(list)
        for run in runs:
            if run.get("duration_ms") is not None:
                by_level[run["concurrency"]].append(float(run["duration_ms"]))

        data = [by_level.get(level, []) for level in levels]
        color = series_color(series)
        bp = ax.boxplot(
            data,
            tick_labels=[str(level) for level in levels],
            showfliers=True,
            patch_artist=True,
        )
        for box in bp["boxes"]:
            box.set_facecolor(color)
            box.set_alpha(0.55)
        for key in ("medians", "whiskers", "caps", "fliers"):
            for artist in bp[key]:
                artist.set_color(color)
        ax.set_title(series)
        ax.set_xlabel("Concurrency level")
        ax.grid(axis="y", alpha=0.3)

    axes[0].set_ylabel("duration_ms")
    fig.suptitle("Raw in-container duration_ms by concurrency")
    fig.text(0.5, 0.01, DURATION_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "duration_boxplots.png", dpi=150)
    plt.close(fig)


def plot_latency_boxplots(
    loaded: dict[str, tuple[list[dict], list[dict]]], out: Path
) -> None:
    levels = all_levels(loaded)
    series_list = list(loaded.keys())
    fig, axes = plt.subplots(
        1, len(series_list), figsize=(4.5 * len(series_list), 5), sharey=True
    )
    if len(series_list) == 1:
        axes = [axes]

    for ax, series in zip(axes, series_list):
        runs, _ = loaded[series]
        by_level: dict[int, list[float]] = defaultdict(list)
        for run in runs:
            by_level[run["concurrency"]].append(float(run["latency_ms"]))

        data = [by_level.get(level, []) for level in levels]
        color = series_color(series)
        bp = ax.boxplot(
            data,
            tick_labels=[str(level) for level in levels],
            showfliers=True,
            patch_artist=True,
        )
        for box in bp["boxes"]:
            box.set_facecolor(color)
            box.set_alpha(0.55)
        for key in ("medians", "whiskers", "caps", "fliers"):
            for artist in bp[key]:
                artist.set_color(color)
        ax.set_title(series)
        ax.set_xlabel("Concurrency level")
        ax.grid(axis="y", alpha=0.3)

    axes[0].set_ylabel("Latency (ms)")
    fig.suptitle("Raw run latency distribution by concurrency")
    fig.text(0.5, 0.01, LATENCY_NOTE, ha="center", fontsize=8, style="italic")
    fig.tight_layout()
    fig.subplots_adjust(bottom=0.18)
    fig.savefig(out / "latency_boxplots.png", dpi=150)
    plt.close(fig)


def main() -> None:
    available = list_benchmark_dirs()
    parser = argparse.ArgumentParser(description="Vera concurrency EDA")
    parser.add_argument(
        "--benchmark",
        default="agent",
        choices=available or None,
        help=(
            "Which data/<benchmark>/ folder to chart "
            f"(found: {', '.join(available) or 'none'})"
        ),
    )
    parser.add_argument(
        "--include",
        nargs="+",
        metavar="SERIES",
        default=None,
        help=(
            "Only these result series (exact folder names under "
            "data/<benchmark>/). Example: --include rlp-phoenix rlp-vera. "
            "Default: every series that has a concurrency_*.jsonl"
        ),
    )
    parser.add_argument(
        "--exclude-levels",
        default="",
        metavar="N[,N...]",
        help=(
            "Comma-separated concurrency levels to omit from the table and charts "
            "(e.g. 352,528,704)"
        ),
    )
    args = parser.parse_args()

    if args.benchmark not in available:
        raise SystemExit(
            f"Unknown benchmark folder {args.benchmark!r}. "
            f"Expected a directory under {DATA_DIR}/ "
            f"(found: {', '.join(available) or 'none'})"
        )

    try:
        sources = discover_datasets(args.benchmark)
    except FileNotFoundError as exc:
        raise SystemExit(str(exc)) from exc

    excluded_levels: set[int] = set()
    for raw in args.exclude_levels.split(","):
        raw = raw.strip()
        if not raw:
            continue
        try:
            excluded_levels.add(int(raw))
        except ValueError as exc:
            raise SystemExit(
                f"Invalid --exclude-levels value {raw!r}; expected integers"
            ) from exc
    if args.include:
        wanted = [series.strip() for series in args.include if series.strip()]
        missing = [s for s in wanted if s not in sources]
        if missing:
            raise SystemExit(
                "No JSONL for --include series: "
                + ", ".join(missing)
                + f". Available: {', '.join(sources) or 'none'}"
            )
        sources = {series: sources[series] for series in wanted}

    metas: dict[str, dict | None] = {}
    loaded: dict[str, tuple[list[dict], list[dict]]] = {}
    for runner, path in sources.items():
        meta, runs, summaries = load_jsonl(path)
        if excluded_levels:
            runs = [r for r in runs if r.get("concurrency") not in excluded_levels]
            summaries = [
                s for s in summaries if s.get("concurrency") not in excluded_levels
            ]
        metas[runner] = meta
        loaded[runner] = (runs, summaries)
    if not any(summaries for _, summaries in loaded.values()):
        raise SystemExit(
            "No concurrency levels remain after --exclude-levels "
            f"({', '.join(str(n) for n in sorted(excluded_levels))})."
        )
    out = OUT_DIR / args.benchmark
    out.mkdir(parents=True, exist_ok=True)

    print(f"benchmark={args.benchmark}")
    if args.include:
        print(f"include={','.join(args.include)}")
    if excluded_levels:
        print(
            "excluded_levels="
            + ",".join(str(n) for n in sorted(excluded_levels))
        )
    print_summary_table(loaded, sources, metas)

    plot_grouped_metric(
        loaded,
        out,
        metric_key="p50_ms",
        title=f"{args.benchmark}: p50 latency by concurrency",
        ylabel="p50 latency (ms)",
        filename="p50_latency_bars.png",
    )
    plot_grouped_metric(
        loaded,
        out,
        metric_key="p95_ms",
        title=f"{args.benchmark}: p95 latency by concurrency",
        ylabel="p95 latency (ms)",
        filename="p95_latency_bars.png",
    )
    plot_grouped_metric(
        loaded,
        out,
        metric_key=None,
        title=f"{args.benchmark}: mean latency by concurrency",
        ylabel="mean latency (ms)",
        filename="mean_latency_bars.png",
        from_runs_mean=True,
    )
    plot_grouped_metric(
        loaded,
        out,
        metric_key=None,
        title=f"{args.benchmark}: mean duration_ms by concurrency",
        ylabel="mean duration_ms",
        filename="mean_duration_bars.png",
        from_runs_mean_duration=True,
        footnote=DURATION_NOTE,
    )
    plot_throughput(loaded, out)
    plot_duration_line(loaded, out)
    plot_chip_speed_vs_concurrency(loaded, out)
    plot_latency_boxplots(loaded, out)
    plot_duration_vs_concurrency(loaded, out)
    plot_duration_boxplots(loaded, out)

    print(f"Wrote charts to {out}/")
    for path in sorted(out.glob("*.png")):
        print(f"  - {path.name}")


if __name__ == "__main__":
    main()

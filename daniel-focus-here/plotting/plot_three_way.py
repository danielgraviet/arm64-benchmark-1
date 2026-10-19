#!/usr/bin/env python3
"""Build one-socket three-way charts: Vera, EPYC 9575F, EPYC 9755.

Style matches daniel-focus-here/graphs/throughput_n45_44_352.png
(x ticks 44–2000, per-point labels, lower-left legend, jobs/sec y axis).

    uv run python daniel-focus-here/plotting/plot_three_way.py
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

FOCUS = Path(__file__).resolve().parent.parent
if str(FOCUS) not in sys.path:
    sys.path.insert(0, str(FOCUS))

from plotting.load import (  # noqa: E402
    load_dense_summaries,
    load_ready_times,
    load_ready_wall,
    mean_std,
    p50_duration_ms,
)
from plotting import sources as src  # noqa: E402
from plotting.style import (  # noqa: E402
    annotate_points,
    apply_style,
    legend_lower_left,
    style_concurrency_axis,
    style_throughput_yaxis,
)

SERIES_ORDER = ("vera", "zen5_9575f", "zen5_9755")


def _dense_by_series() -> dict[str, dict[int, dict]]:
    out: dict[str, dict[int, dict]] = {}
    for key in SERIES_ORDER:
        path = src.DENSE[key]
        if not path.is_file():
            raise FileNotFoundError(path)
        out[key] = load_dense_summaries(path)
    return out


def _shared_levels(dense: dict[str, dict[int, dict]]) -> list[int]:
    levels: set[int] | None = None
    for key in SERIES_ORDER:
        keys = set(dense[key])
        levels = keys if levels is None else levels & keys
    if not levels:
        raise RuntimeError("no overlapping concurrency levels across series")
    return sorted(levels)


def plot_throughput_lines(dense: dict[str, dict[int, dict]], out: Path) -> None:
    levels = _shared_levels(dense)
    fig, ax = plt.subplots(figsize=(13.0, 5.0))
    for key in SERIES_ORDER:
        ys = [float(dense[key][c].get("throughput_per_sec") or 0) for c in levels]
        color = src.COLORS[key]
        ax.plot(
            levels,
            ys,
            marker="o",
            linewidth=2.4,
            label=src.LABELS[key],
            color=color,
        )
        annotate_points(
            ax,
            levels,
            ys,
            color=color,
            offset=src.ANNOTATE_OFFSET[key],
        )
    ax.set_title(f"Agent throughput vs concurrency (n=45, through {max(levels)})")
    style_concurrency_axis(ax, levels)
    style_throughput_yaxis(ax)
    legend_lower_left(ax)
    fig.tight_layout()
    fig.savefig(out / "throughput_3way_44_2000.png", dpi=180)
    plt.close(fig)


def plot_p50_duration_lines(dense: dict[str, dict[int, dict]], out: Path) -> None:
    levels = _shared_levels(dense)
    fig, ax = plt.subplots(figsize=(13.0, 5.0))
    # Duration climbs with concurrency: Vera lowest, so label Vera below and Zen above.
    duration_offsets = {
        "vera": -14,
        "zen5_9755": 8,
        "zen5_9575f": 14,
    }
    for key in SERIES_ORDER:
        ys = [p50_duration_ms(dense[key][c]) / 1000.0 for c in levels]
        color = src.COLORS[key]
        ax.plot(
            levels,
            ys,
            marker="o",
            linewidth=2.4,
            label=src.LABELS[key],
            color=color,
        )
        annotate_points(
            ax,
            levels,
            ys,
            color=color,
            offset=duration_offsets[key],
        )
    ax.set_title(f"Agent p50 duration vs concurrency (n=45, through {max(levels)})")
    ax.set_ylabel("p50 duration (seconds)")
    ax.set_ylim(bottom=0)
    style_concurrency_axis(ax, levels)
    legend_lower_left(ax)
    fig.tight_layout()
    fig.savefig(out / "p50_duration_3way_44_2000.png", dpi=180)
    plt.close(fig)


def plot_create_1000_bars(out: Path) -> None:
    means = []
    stds = []
    labels = []
    colors = []
    for key in SERIES_ORDER:
        path = src.READY_1K[key]
        if not path.is_file():
            raise FileNotFoundError(path)
        times = load_ready_times(path)
        mean, std = mean_std(times)
        means.append(mean)
        stds.append(std)
        labels.append(src.LABELS[key])
        colors.append(src.COLORS[key])

    fig, ax = plt.subplots(figsize=(7, 4.2))
    x = np.arange(len(labels))
    bars = ax.bar(x, means, yerr=stds, color=colors, capsize=5, width=0.65)
    for bar, mean, std in zip(bars, means, stds):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            mean + std + 1.0,
            f"{mean:.1f}s",
            ha="center",
            fontsize=10,
        )
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("READY_WALL_S")
    ax.set_title("Create and ready 1000 agent sandboxes")
    ax.set_ylim(0, max(m + s for m, s in zip(means, stds)) * 1.25)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out / "create_1000_3way.png", dpi=180)
    plt.close(fig)


def plot_create_2000_spread(out: Path) -> None:
    """Vera vs 9575F create-ready 2000. Bars are medians. Dots are repeats."""
    keys = ("vera", "zen5_9575f")
    series: list[list[float]] = []
    medians: list[float] = []
    for key in keys:
        times = [load_ready_wall(path) for path in src.READY_2K_RUNS[key]]
        ordered = sorted(times)
        mid = len(ordered) // 2
        if len(ordered) % 2:
            median = ordered[mid]
        else:
            median = (ordered[mid - 1] + ordered[mid]) / 2
        series.append(times)
        medians.append(median)

    fig, ax = plt.subplots(figsize=(7.2, 4.8))
    x = np.arange(len(keys))
    colors = [src.COLORS[key] for key in keys]
    labels = [src.LABELS[key] for key in keys]
    ax.bar(x, medians, color=colors, width=0.62, zorder=1)
    for i, times in enumerate(series):
        ordered = sorted(times)
        span = 0.36
        if len(ordered) == 1:
            offsets = [0.0]
        else:
            offsets = [
                -span / 2 + span * j / (len(ordered) - 1) for j in range(len(ordered))
            ]
        for t, dx in zip(ordered, offsets):
            ax.scatter(i + dx, t, s=36, color="#202124", zorder=3)
        clusters: list[list[float]] = []
        for t in ordered:
            if clusters and t - clusters[-1][-1] < 8:
                clusters[-1].append(t)
            else:
                clusters.append([t])
        for cluster in clusters:
            anchor = cluster[len(cluster) // 2]
            if len(cluster) == 1:
                text = f"{cluster[0]:.0f}"
            else:
                text = f"{cluster[0]:.0f}-{cluster[-1]:.0f}"
            ax.annotate(
                text,
                (i + 0.34, anchor),
                textcoords="offset points",
                xytext=(6, 0),
                va="center",
                ha="left",
                fontsize=8,
                color="#202124",
            )
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("READY_WALL_S")
    ax.set_title("Create and ready 2000 sandboxes (median bar, repeats as dots)")
    ax.set_ylim(0, 175)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out / "create_2000_vera_9575f.png", dpi=180)
    plt.close(fig)


def plot_peak_throughput_bars(dense: dict[str, dict[int, dict]], out: Path) -> None:
    peaks = []
    peak_at = []
    labels = []
    colors = []
    for key in SERIES_ORDER:
        best_c = max(
            dense[key],
            key=lambda c: float(dense[key][c].get("throughput_per_sec") or 0),
        )
        peaks.append(float(dense[key][best_c].get("throughput_per_sec") or 0))
        peak_at.append(best_c)
        labels.append(src.LABELS[key])
        colors.append(src.COLORS[key])

    fig, ax = plt.subplots(figsize=(7, 4.5))
    x = np.arange(len(labels))
    bars = ax.bar(x, peaks, color=colors, width=0.65)
    for bar, peak, c in zip(bars, peaks, peak_at):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            peak + 0.25,
            f"{peak:.1f}\n@{c}",
            ha="center",
            va="bottom",
            fontsize=9,
        )
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("Completed agent jobs / sec")
    ax.set_title("Peak packed agent throughput (n=45 ladder)")
    style_throughput_yaxis(ax)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out / "peak_throughput_3way.png", dpi=180)
    plt.close(fig)


def plot_throughput_at_2000_bars(
    dense: dict[str, dict[int, dict]], out: Path
) -> None:
    vals = []
    labels = []
    colors = []
    for key in SERIES_ORDER:
        row = dense[key].get(2000)
        if row is None:
            raise KeyError(f"{key} missing concurrency 2000")
        vals.append(float(row.get("throughput_per_sec") or 0))
        labels.append(src.LABELS[key])
        colors.append(src.COLORS[key])

    fig, ax = plt.subplots(figsize=(7, 4.5))
    x = np.arange(len(labels))
    bars = ax.bar(x, vals, color=colors, width=0.65)
    for bar, val in zip(bars, vals):
        ax.text(
            bar.get_x() + bar.get_width() / 2,
            val + 0.25,
            f"{val:.1f}",
            ha="center",
            va="bottom",
            fontsize=10,
        )
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("Completed agent jobs / sec")
    ax.set_title("Agent throughput at 2000 concurrent sandboxes")
    style_throughput_yaxis(ax)
    ax.grid(axis="y", alpha=0.25)
    fig.tight_layout()
    fig.savefig(out / "throughput_at_2000_3way.png", dpi=180)
    plt.close(fig)


def main() -> None:
    apply_style()
    src.GRAPHS.mkdir(parents=True, exist_ok=True)
    dense = _dense_by_series()
    plot_throughput_lines(dense, src.GRAPHS)
    plot_p50_duration_lines(dense, src.GRAPHS)
    plot_create_1000_bars(src.GRAPHS)
    plot_create_2000_spread(src.GRAPHS)
    plot_peak_throughput_bars(dense, src.GRAPHS)
    plot_throughput_at_2000_bars(dense, src.GRAPHS)
    print(f"wrote charts under {src.GRAPHS}")
    for name in (
        "throughput_3way_44_2000.png",
        "p50_duration_3way_44_2000.png",
        "create_1000_3way.png",
        "create_2000_vera_9575f.png",
        "peak_throughput_3way.png",
        "throughput_at_2000_3way.png",
    ):
        print(" ", name, "ok" if (src.GRAPHS / name).is_file() else "MISSING")


if __name__ == "__main__":
    main()

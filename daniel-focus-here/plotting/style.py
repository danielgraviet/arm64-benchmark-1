"""Shared matplotlib style for focus-pack charts.

Matches the published Vera share look (throughput_n45_44_352.png).
"""

from __future__ import annotations

from typing import Sequence

import matplotlib.pyplot as plt
from matplotlib.axes import Axes


def apply_style() -> None:
    plt.rcParams.update(
        {
            "figure.facecolor": "white",
            "axes.facecolor": "white",
            "axes.grid": True,
            "grid.alpha": 0.25,
            "font.size": 11,
            "axes.titlesize": 13,
            "axes.labelsize": 11,
            "legend.fontsize": 10,
        }
    )


def annotate_points(
    ax: Axes,
    xs: Sequence[int],
    ys: Sequence[float],
    *,
    color: str,
    offset: int,
    fmt: str = "{:.1f}",
) -> None:
    for x, y in zip(xs, ys):
        ax.annotate(
            fmt.format(y),
            (x, y),
            textcoords="offset points",
            xytext=(0, offset),
            ha="center",
            fontsize=8,
            color=color,
        )


def style_concurrency_axis(ax: Axes, levels: Sequence[int]) -> None:
    ax.set_xlabel("Concurrent sandboxes")
    ax.set_xticks(list(levels))
    ax.set_xticklabels([str(level) for level in levels], rotation=30, ha="right")
    ax.grid(True, alpha=0.25)


def style_throughput_yaxis(ax: Axes) -> None:
    """Y axis like the published n=45 chart: 0, 2, …, 12."""
    ax.set_ylabel("Completed agent jobs / sec")
    ax.set_ylim(0, 14)
    ax.set_yticks(list(range(0, 13, 2)))
    ax.set_yticklabels([str(t) for t in range(0, 13, 2)])


def legend_lower_left(ax: Axes) -> None:
    ax.legend(frameon=False, loc="lower left")

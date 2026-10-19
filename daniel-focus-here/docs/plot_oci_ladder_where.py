#!/usr/bin/env python3
"""Draw the two figures embedded in oci-ladder-where-the-time-goes.md.

    uv run python daniel-focus-here/docs/plot_oci_ladder_where.py

Writes oci-ladder-jobs.png and oci-ladder-wave.png next to this file.
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt

DOCS = Path(__file__).resolve().parent
if str(DOCS) not in sys.path:
    sys.path.insert(0, str(DOCS))

from oci_ladder_where_load import LadderLevel, load_pair  # noqa: E402

THIS_BOX = "#76B900"
THIS_BOX_LIGHT = "#C5E38A"
ONSITE = "#3D6B00"
ONSITE_LIGHT = "#A8C96A"
ZEN5 = "#6F7177"
ZEN5_LIGHT = "#C5C6C9"


def _apply_style() -> None:
    plt.rcParams.update(
        {
            "figure.facecolor": "white",
            "axes.facecolor": "white",
            "axes.grid": False,
            "font.size": 11,
            "axes.titlesize": 13,
            "axes.labelsize": 11,
            "legend.fontsize": 10,
        }
    )


def _by_concurrency(levels: list[LadderLevel]) -> dict[int, LadderLevel]:
    return {level.concurrency: level for level in levels}


def plot_jobs(
    oci: list[LadderLevel],
    onsite: list[LadderLevel],
    zen5: list[LadderLevel],
    out: Path,
) -> None:
    _apply_style()
    fig, ax = plt.subplots(figsize=(7.4, 3.3))
    ax.grid(axis="y", alpha=0.28)
    xs = [level.concurrency for level in oci]
    onsite_map = _by_concurrency(onsite)
    zen5_map = _by_concurrency(zen5)
    ax.plot(
        xs,
        [level.throughput_per_sec for level in oci],
        color=THIS_BOX,
        marker="o",
        linewidth=2.2,
        label="OCI Vera",
    )
    ax.plot(
        xs,
        [onsite_map[x].throughput_per_sec for x in xs],
        color=ONSITE,
        marker="o",
        linewidth=2.2,
        label="Vera HQ",
    )
    ax.plot(
        xs,
        [zen5_map[x].throughput_per_sec for x in xs],
        color=ZEN5,
        marker="o",
        linewidth=2.2,
        label="9575F",
    )
    shown = {44, 88, 176, 352, 704, 1408, 2000}
    ax.set_xticks(xs)
    ax.set_xticklabels([str(x) if x in shown else "" for x in xs])
    ax.set_ylim(0, 16)
    ax.set_xlabel("Sandboxes")
    ax.set_ylabel("Jobs per second")
    ax.set_title("Packed jobs per second")
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.5, -0.18),
        ncol=3,
        frameon=False,
    )
    fig.savefig(out, dpi=160, bbox_inches="tight")
    plt.close(fig)


def plot_wave_level(
    oci: list[LadderLevel],
    onsite: list[LadderLevel],
    zen5: list[LadderLevel],
    concurrency: int,
    out: Path,
) -> None:
    """One concurrency. Vertical stacks in seconds, so a shorter bar is faster."""
    rows = (
        ("OCI Vera", _by_concurrency(oci)[concurrency]),
        ("Vera HQ", _by_concurrency(onsite)[concurrency]),
        ("9575F", _by_concurrency(zen5)[concurrency]),
    )
    create_color = "#6F7177"
    jobs_color = "#76B900"
    teardown_color = "#D9DADD"
    _apply_style()
    fig, ax = plt.subplots(figsize=(6.2, 3.6))
    ax.grid(axis="y", alpha=0.28)
    labels = [label for label, _level in rows]
    for pos, (_label, level) in enumerate(rows):
        ax.bar(pos, level.create_wall_s, color=create_color, width=0.62)
        ax.bar(
            pos,
            level.exec_wall_s,
            bottom=level.create_wall_s,
            color=jobs_color,
            width=0.62,
        )
        ax.bar(
            pos,
            level.delete_wall_s,
            bottom=level.create_wall_s + level.exec_wall_s,
            color=teardown_color,
            width=0.62,
        )
    ax.set_xticks(list(range(len(rows))), labels)
    ax.set_ylabel("Seconds")
    ax.set_title(f"{concurrency} sandboxes")
    from matplotlib.patches import Patch

    ax.legend(
        handles=[
            Patch(facecolor=create_color, label="Create"),
            Patch(facecolor=jobs_color, label="Jobs"),
            Patch(facecolor=teardown_color, label="Teardown"),
        ],
        frameon=False,
        fontsize=11,
    )
    fig.savefig(out, dpi=160, bbox_inches="tight")
    plt.close(fig)


def plot_job_steps(out: Path) -> None:
    """One local run of the n=45 job. Shares match the note's last table."""
    steps = (
        ("Writing, searching, and the patches", 0.8, "under 1%"),
        ("Parsing the files", 3.0, "3%"),
        ("Short pytest that is supposed to fail", 4.0, "4%"),
        ("Heavy pytest", 92.0, "92%"),
    )
    _apply_style()
    fig, ax = plt.subplots(figsize=(7.4, 2.8))
    ax.grid(axis="x", alpha=0.28)
    positions = list(range(len(steps)))
    labels = [name for name, _share, _text in steps]
    shares = [share for _name, share, _text in steps]
    texts = [text for _name, _share, text in steps]
    ax.barh(positions, shares, color=THIS_BOX, height=0.62)
    for pos, share, text in zip(positions, shares, texts):
        ax.text(max(share, 1) + 1.5, pos, text, va="center", fontsize=11)
    ax.set_yticks(positions, labels)
    ax.set_xlabel("Share of one job")
    ax.set_xlim(0, 110)
    ax.set_title("Inside one job")
    fig.savefig(out, dpi=160, bbox_inches="tight")
    plt.close(fig)


def main() -> None:
    oci, onsite, zen5 = load_pair()
    jobs_path = DOCS / "oci-ladder-jobs-176.png"
    steps_path = DOCS / "oci-ladder-job-steps.png"
    plot_jobs(oci, onsite, zen5, jobs_path)
    for concurrency in (44, 352, 1408, 2000):
        wave_path = DOCS / f"oci-ladder-wave-{concurrency}-sec.png"
        plot_wave_level(oci, onsite, zen5, concurrency, wave_path)
        print(f"wrote {wave_path}")
    plot_job_steps(steps_path)
    onsite_map = _by_concurrency(onsite)
    zen5_map = _by_concurrency(zen5)
    for level in oci:
        other = onsite_map[level.concurrency]
        amd = zen5_map[level.concurrency]
        print(
            f"c={level.concurrency} box={level.throughput_per_sec:.2f} "
            f"onsite={other.throughput_per_sec:.2f} "
            f"9575={amd.throughput_per_sec:.2f} "
            f"fail={level.failures}/{other.failures}/{amd.failures}"
        )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Draw the two figures embedded in oci-create-where-the-time-goes.md.

    uv run python daniel-focus-here/docs/plot_oci_create_where.py

Writes oci-create-line.png and oci-create-start-steps.png next to this file.
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib.pyplot as plt

DOCS = Path(__file__).resolve().parent
if str(DOCS) not in sys.path:
    sys.path.insert(0, str(DOCS))

from oci_create_where_load import CreateRun, load_runs  # noqa: E402

ACCEPT = "#3B6D9A"
PICKUP = "#E0A106"
LINE = "#1F4E79"


def _mean(values: list[float]) -> float:
    return sum(values) / len(values)


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


def plot_line(runs: list[CreateRun], out: Path) -> None:
    """First, typical, and last sandbox. The 80 ms start is too small to stack."""
    labels = ["Last", "Typical", "First"]
    accept = [
        _mean([run.last.post_s for run in runs]),
        _mean([run.typical_post_s for run in runs]),
        _mean([run.first.post_s for run in runs]),
    ]
    pickup = [
        _mean([run.last.wait_s for run in runs]),
        _mean([run.typical_wait_s for run in runs]),
        _mean([run.first.wait_s for run in runs]),
    ]
    ready = [accept[i] + pickup[i] for i in range(3)]

    _apply_style()
    fig, ax = plt.subplots(figsize=(7.4, 2.7))
    ax.grid(axis="x", alpha=0.28)
    positions = [0, 1, 2]
    ax.barh(positions, accept, color=ACCEPT, label="Waiting for the control plane", height=0.62)
    ax.barh(
        positions,
        pickup,
        left=accept,
        color=PICKUP,
        label="Waiting for a runner",
        height=0.62,
    )
    ax.set_yticks(positions, labels)
    ax.set_xlabel("Seconds until that sandbox is ready")
    ax.set_xlim(0, 20)
    ax.set_title("The line in front of an 80 millisecond start")
    for pos, seconds in zip(positions, ready):
        ax.text(seconds + 0.25, pos, f"{seconds:.1f}s", va="center", fontsize=11)
    ax.legend(
        loc="upper center",
        bbox_to_anchor=(0.5, -0.28),
        ncol=2,
        frameon=False,
    )
    fig.savefig(out, dpi=160, bbox_inches="tight")
    plt.close(fig)


def plot_start_steps(runs: list[CreateRun], out: Path) -> None:
    """Per-sandbox start steps. They overlap, so the total stays near 80 ms."""
    steps = [
        ("Command check", _mean([run.typical_probe_s for run in runs]) * 1000.0),
        ("Guest ready", _mean([run.guest_ready_p50_ms for run in runs])),
        ("Start the VM", _mean([run.vm_start_p50_ms for run in runs])),
        ("Load memory", _mean([run.memory_p50_ms for run in runs])),
        ("Scratch disk", _mean([run.scratch_p50_ms for run in runs])),
    ]
    together = _mean([run.boot_p50_ms for run in runs])

    _apply_style()
    fig, ax = plt.subplots(figsize=(7.4, 2.7))
    ax.grid(axis="x", alpha=0.28)
    positions = list(range(len(steps)))
    labels = [name for name, _ms in steps]
    values = [ms for _name, ms in steps]
    colors = [PICKUP if name == "Command check" else ACCEPT for name in labels]
    ax.barh(positions, values, color=colors, height=0.62)
    ax.axvline(together, color=LINE, linewidth=1.6, label=f"Together, {together:.0f} ms")
    ax.set_yticks(positions, labels)
    ax.set_xlabel("Milliseconds. Scratch, memory, the VM, and guest ready overlap.")
    ax.set_xlim(0, 110)
    ax.set_title("Steps inside one sandbox start")
    for pos, ms in zip(positions, values):
        ax.text(ms + 1.5, pos, f"{ms:.0f} ms", va="center", fontsize=11)
    ax.legend(loc="lower right", frameon=False)
    fig.tight_layout()
    fig.savefig(out, dpi=160)
    plt.close(fig)


def main() -> None:
    runs = load_runs()
    line_path = DOCS / "oci-create-line.png"
    steps_path = DOCS / "oci-create-start-steps.png"
    plot_line(runs, line_path)
    plot_start_steps(runs, steps_path)
    print(f"wrote {line_path}")
    print(f"wrote {steps_path}")
    for run in runs:
        print(
            f"{run.path.name} wall={run.wall_s:.2f}s "
            f"first={run.first.create_s:.2f}s "
            f"typical={run.typical_create_s:.2f}s "
            f"last={run.last.create_s:.2f}s "
            f"boot_p50={run.boot_p50_ms:.0f}ms"
        )


if __name__ == "__main__":
    main()

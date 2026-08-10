"""Unit tests for analytics (B2) pipeline."""

from __future__ import annotations

from analytics.pipeline import run


def test_analytics_deterministic_checksum_inputs() -> None:
    a = run(n=1, seed=42)
    b = run(n=1, seed=42)
    assert a == b


def test_analytics_seed_changes_result() -> None:
    a = run(n=1, seed=42)
    b = run(n=1, seed=43)
    assert a["top_customers"] != b["top_customers"] or a["filtered_line_count"] != b[
        "filtered_line_count"
    ]


def test_analytics_scales_with_n() -> None:
    small = run(n=1, seed=7)
    large = run(n=2, seed=7)
    assert large["customers"] == small["customers"] * 2
    assert large["orders"] == small["orders"] * 2
    assert large["items"] == small["items"] * 2

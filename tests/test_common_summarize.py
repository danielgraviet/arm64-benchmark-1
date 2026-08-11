"""Tests for harness summarize / duration + warm latency fields."""

from __future__ import annotations

from harness.common import summarize


def test_summarize_includes_duration_and_warm() -> None:
    records = [
        {
            "latency_ms": 5000.0,
            "duration_ms": 3000,
            "exit_code": 0,
            "checksum": "abc",
            "cold": True,
            "episode_idx": 0,
        },
        {
            "latency_ms": 3100.0,
            "duration_ms": 3050,
            "exit_code": 0,
            "checksum": "abc",
            "cold": False,
            "episode_idx": 1,
        },
        {
            "latency_ms": 3200.0,
            "duration_ms": 3010,
            "exit_code": 0,
            "checksum": "abc",
            "cold": False,
            "episode_idx": 2,
        },
    ]
    summary = summarize(records, wall_time_s=10.0)
    assert summary["checksum_ok"] is True
    assert summary["runs"] == 3
    assert summary["p50_duration_ms"] == 3010.0
    assert summary["max_duration_ms"] == 3050.0
    assert summary["p50_warm_ms"] == 3150.0
    assert summary["p99_warm_ms"] >= 3150.0

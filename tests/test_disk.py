"""Unit tests for sandbox-disk pipeline."""

from __future__ import annotations

from disk.pipeline import FILES_PER_N, MIB, bytes_for_n, files_for_n, run


def test_disk_deterministic() -> None:
    a = run(n=1, seed=42)
    b = run(n=1, seed=42)
    assert a == b


def test_disk_seed_changes_result() -> None:
    a = run(n=1, seed=42)
    b = run(n=1, seed=43)
    assert a["seq_sha256"] != b["seq_sha256"]
    assert a["small_content_sha256"] != b["small_content_sha256"]


def test_disk_scales_with_n() -> None:
    small = run(n=1, seed=7)
    large = run(n=2, seed=7)
    assert small["seq_bytes"] == MIB
    assert large["seq_bytes"] == bytes_for_n(2)
    assert large["seq_bytes"] == small["seq_bytes"] * 2
    assert small["files_touched"] == FILES_PER_N
    assert large["files_touched"] == files_for_n(2)
    assert large["bytes_written"] > small["bytes_written"]

"""Unit tests for media (FFmpeg) pipeline."""

from __future__ import annotations

import shutil

import pytest

from media.pipeline import FRAMES_PER_N, frame_count, run

pytestmark = pytest.mark.skipif(
    shutil.which("ffmpeg") is None,
    reason="ffmpeg not installed",
)


def test_media_deterministic() -> None:
    a = run(n=1, seed=42)
    b = run(n=1, seed=42)
    assert a == b


def test_media_seed_changes_result() -> None:
    a = run(n=1, seed=42)
    b = run(n=1, seed=43)
    assert a["input_sha256"] != b["input_sha256"]
    assert a["framemd5_sha256"] != b["framemd5_sha256"]


def test_media_scales_with_n() -> None:
    small = run(n=1, seed=7)
    large = run(n=2, seed=7)
    assert small["frames"] == FRAMES_PER_N
    assert large["frames"] == frame_count(2)
    assert large["frames"] == small["frames"] * 2
    assert large["decoded_frames"] == large["frames"]

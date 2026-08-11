"""Unit tests for RL rollout (B3) episode loop."""

from __future__ import annotations

from rl.agent import compute_checksum
from rl.rollout import run_episode


def test_rl_deterministic_same_seed() -> None:
    a = run_episode(n=16, seed=42)
    b = run_episode(n=16, seed=42)
    assert a == b
    assert compute_checksum(a) == compute_checksum(b)


def test_rl_seed_changes_result() -> None:
    a = run_episode(n=16, seed=42)
    b = run_episode(n=16, seed=43)
    assert a["return"] != b["return"] or a["action_histogram"] != b["action_histogram"]
    assert compute_checksum(a) != compute_checksum(b)


def test_rl_horizon_scales_step_count() -> None:
    from rl.env import BATCH_SIZE

    small = run_episode(n=8, seed=7)
    large = run_episode(n=32, seed=7)
    assert small["steps"] == 8
    assert large["steps"] == 32
    assert small["batch_size"] == BATCH_SIZE
    assert sum(small["action_histogram"]) == 8 * BATCH_SIZE
    assert sum(large["action_histogram"]) == 32 * BATCH_SIZE
    assert compute_checksum(small) != compute_checksum(large)

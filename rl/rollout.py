"""Episode rollout loop: reset → n sequential steps → trajectory summary."""

from __future__ import annotations

from typing import Any

import numpy as np

from rl.env import ACTION_DIM, GridEnv
from rl.policy import MockPolicy


def _bootstrap_value(rewards: list[float], gamma: float = 0.99) -> float:
    """Local return reduce (no network) — extra sequential CPU at episode end."""
    g = 0.0
    for r in reversed(rewards):
        g = r + gamma * g
    return float(g)


def _stable_float(x: float, *, ndigits: int = 10) -> float:
    """Round so checksums agree across Darwin/Linux BLAS float noise."""
    return round(float(x), ndigits)


def run_episode(n: int, seed: int) -> dict[str, Any]:
    """Run one mocked RL episode of ``n`` sequential steps.

    Returns a structured summary used for the harness checksum (not wall time).
    Floats are rounded so the same ``(n, seed)`` checksum matches across hosts.
    """
    if n < 1:
        raise ValueError("n (episode horizon) must be >= 1")

    env = GridEnv(seed)
    policy = MockPolicy(seed)

    obs = env.reset()
    rewards: list[float] = []
    actions: list[int] = []
    logits_sum = np.zeros(ACTION_DIM, dtype=np.float64)
    trajectory_obs: list[np.ndarray] = []

    for _ in range(n):
        action, logits = policy.act(obs)
        next_obs, reward, _done = env.step(action)
        actions.append(action)
        rewards.append(reward)
        logits_sum += logits
        trajectory_obs.append(obs)
        obs = next_obs

    hist = [0] * ACTION_DIM
    for a in actions:
        hist[a] += 1

    returns = _bootstrap_value(rewards)
    last_obs = obs
    # Cheap bandwidth-ish touch: mean of stacked observations.
    stacked = np.stack(trajectory_obs, axis=0)
    obs_mean = stacked.mean(axis=0)

    return {
        "steps": n,
        "seed": seed,
        "return": _stable_float(returns),
        "reward_sum": _stable_float(sum(rewards)),
        "action_histogram": hist,
        "logits_sum": [_stable_float(x) for x in logits_sum],
        "last_obs_norm": _stable_float(np.linalg.norm(last_obs)),
        "obs_mean_norm": _stable_float(np.linalg.norm(obs_mean)),
        "last_obs_head": [_stable_float(x) for x in last_obs[:8]],
    }

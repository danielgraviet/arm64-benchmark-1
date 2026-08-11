"""Episode rollout loop: reset → n sequential steps → summary (no full traj)."""

from __future__ import annotations

from typing import Any

import numpy as np

from rl.env import ACTION_DIM, BATCH_SIZE, GridEnv
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
    """Run one mocked RL episode of ``n`` sequential batched steps.

    Returns a structured summary used for the harness checksum (not wall time).
    Floats are rounded so the same ``(n, seed)`` checksum matches across hosts.

    Does **not** store the full observation trajectory (avoids allocator noise
    at large horizons). Keeps a running observation mean for checksum material.
    """
    if n < 1:
        raise ValueError("n (episode horizon) must be >= 1")

    env = GridEnv(seed)
    policy = MockPolicy(seed)

    obs = env.reset()
    # Mean reward across batch each step → scalar sequence for return.
    rewards: list[float] = []
    hist = [0] * ACTION_DIM
    logits_sum = np.zeros(ACTION_DIM, dtype=np.float64)
    obs_mean_acc = np.zeros(env.obs_dim, dtype=np.float64)

    for _ in range(n):
        actions, logits = policy.act(obs)
        next_obs, reward, _done = env.step(actions)
        rewards.append(float(np.mean(reward)))
        for a in actions.tolist():
            hist[int(a)] += 1
        logits_sum += logits.sum(axis=0)
        obs_mean_acc += obs.mean(axis=0)
        obs = next_obs

    returns = _bootstrap_value(rewards)
    last_obs = obs.mean(axis=0)
    obs_mean = obs_mean_acc / n

    return {
        "steps": n,
        "seed": seed,
        "batch_size": BATCH_SIZE,
        "return": _stable_float(returns),
        "reward_sum": _stable_float(sum(rewards)),
        "action_histogram": hist,
        "logits_sum": [_stable_float(x) for x in logits_sum],
        "last_obs_norm": _stable_float(np.linalg.norm(last_obs)),
        "obs_mean_norm": _stable_float(np.linalg.norm(obs_mean)),
        "last_obs_head": [_stable_float(x) for x in last_obs[:8]],
    }

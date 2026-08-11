"""Deterministic local RL environment (no network / pygame)."""

from __future__ import annotations

import numpy as np

OBS_DIM = 256
ACTION_DIM = 8
HIDDEN_DIM = 128


class GridEnv:
    """Fixed-size observation env with seeded transitions.

    State is a latent vector evolved by a cheap linear update plus
    action-dependent drift — enough CPU work without external deps.
    """

    def __init__(self, seed: int, *, obs_dim: int = OBS_DIM) -> None:
        self.obs_dim = obs_dim
        self.action_dim = ACTION_DIM
        self._rng = np.random.default_rng(seed)
        self._transition = self._rng.standard_normal((obs_dim, obs_dim)).astype(
            np.float64
        ) * (1.0 / np.sqrt(obs_dim))
        self._action_embed = self._rng.standard_normal((ACTION_DIM, obs_dim)).astype(
            np.float64
        ) * (1.0 / np.sqrt(ACTION_DIM))
        self._obs: np.ndarray | None = None
        self._step_count = 0

    def reset(self) -> np.ndarray:
        self._obs = self._rng.standard_normal(self.obs_dim).astype(np.float64)
        self._obs /= np.linalg.norm(self._obs) + 1e-12
        self._step_count = 0
        return self._obs.copy()

    def step(self, action: int) -> tuple[np.ndarray, float, bool]:
        if self._obs is None:
            raise RuntimeError("call reset() before step()")
        a = int(action) % self.action_dim
        drift = self._action_embed[a]
        nxt = self._transition @ self._obs + 0.1 * drift
        nxt = np.tanh(nxt)
        reward = float(-np.sum(nxt * nxt) / self.obs_dim + 0.05 * a)
        self._obs = nxt
        self._step_count += 1
        return self._obs.copy(), reward, False

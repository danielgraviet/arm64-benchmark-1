"""Deterministic local RL environment (no network / pygame)."""

from __future__ import annotations

import numpy as np

# Chart A–oriented sizes: enough per-step FLOPs that moderate horizons
# yield multi-second duration_ms on cloud sandboxes (not only on a laptop).
OBS_DIM = 384
ACTION_DIM = 16
HIDDEN_DIM = 192
# Vectorized envs per “step” — mimics batched rollout without external deps.
BATCH_SIZE = 8


class GridEnv:
    """Fixed-size observation env with seeded transitions.

    State is a latent vector evolved by a linear update plus action-dependent
    drift. Supports a small batch of independent latents for denser FLOPs.
    """

    def __init__(
        self,
        seed: int,
        *,
        obs_dim: int = OBS_DIM,
        batch_size: int = BATCH_SIZE,
    ) -> None:
        self.obs_dim = obs_dim
        self.action_dim = ACTION_DIM
        self.batch_size = batch_size
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
        obs = self._rng.standard_normal((self.batch_size, self.obs_dim)).astype(
            np.float64
        )
        norms = np.linalg.norm(obs, axis=1, keepdims=True) + 1e-12
        self._obs = obs / norms
        self._step_count = 0
        return self._obs.copy()

    def step(self, actions: np.ndarray) -> tuple[np.ndarray, np.ndarray, bool]:
        if self._obs is None:
            raise RuntimeError("call reset() before step()")
        a = np.asarray(actions, dtype=np.int64) % self.action_dim
        drift = self._action_embed[a]  # (batch, obs_dim)
        nxt = self._obs @ self._transition.T + 0.1 * drift
        nxt = np.tanh(nxt)
        reward = -np.sum(nxt * nxt, axis=1) / self.obs_dim + 0.05 * a.astype(
            np.float64
        )
        self._obs = nxt
        self._step_count += 1
        return self._obs.copy(), reward, False

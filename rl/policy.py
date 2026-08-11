"""Mock policy: local NumPy forward only (no GPU / downloads)."""

from __future__ import annotations

import numpy as np

from rl.env import ACTION_DIM, HIDDEN_DIM, OBS_DIM


class MockPolicy:
    """Three-layer matmul “forward” with seeded weights (batched)."""

    def __init__(
        self,
        seed: int,
        *,
        obs_dim: int = OBS_DIM,
        hidden_dim: int = HIDDEN_DIM,
        action_dim: int = ACTION_DIM,
    ) -> None:
        rng = np.random.default_rng(seed ^ 0xC0FFEE)
        scale1 = 1.0 / np.sqrt(obs_dim)
        scale2 = 1.0 / np.sqrt(hidden_dim)
        scale3 = 1.0 / np.sqrt(hidden_dim)
        self.w1 = rng.standard_normal((obs_dim, hidden_dim)).astype(np.float64) * scale1
        self.b1 = rng.standard_normal(hidden_dim).astype(np.float64) * 0.01
        self.w2 = (
            rng.standard_normal((hidden_dim, hidden_dim)).astype(np.float64) * scale2
        )
        self.b2 = rng.standard_normal(hidden_dim).astype(np.float64) * 0.01
        self.w3 = (
            rng.standard_normal((hidden_dim, action_dim)).astype(np.float64) * scale3
        )
        self.b3 = rng.standard_normal(action_dim).astype(np.float64) * 0.01

    def logits(self, observation: np.ndarray) -> np.ndarray:
        # observation: (batch, obs_dim) or (obs_dim,)
        h1 = np.tanh(observation @ self.w1 + self.b1)
        h2 = np.tanh(h1 @ self.w2 + self.b2)
        return h2 @ self.w3 + self.b3

    def act(self, observation: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        logits = self.logits(observation)
        if logits.ndim == 1:
            logits = logits[None, :]
        # Softmax per batch row (extra FLOPs, deterministic).
        shifted = logits - np.max(logits, axis=1, keepdims=True)
        exp = np.exp(shifted)
        probs = exp / np.sum(exp, axis=1, keepdims=True)
        actions = np.argmax(probs, axis=1).astype(np.int64)
        return actions, logits

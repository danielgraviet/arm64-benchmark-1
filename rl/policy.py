"""Mock policy: local NumPy forward only (no GPU / downloads)."""

from __future__ import annotations

import numpy as np

from rl.env import ACTION_DIM, HIDDEN_DIM, OBS_DIM


class MockPolicy:
    """Two-layer matmul “forward” with seeded weights."""

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
        self.w1 = rng.standard_normal((obs_dim, hidden_dim)).astype(np.float64) * scale1
        self.b1 = rng.standard_normal(hidden_dim).astype(np.float64) * 0.01
        self.w2 = (
            rng.standard_normal((hidden_dim, action_dim)).astype(np.float64) * scale2
        )
        self.b2 = rng.standard_normal(action_dim).astype(np.float64) * 0.01

    def logits(self, observation: np.ndarray) -> np.ndarray:
        h = np.tanh(observation @ self.w1 + self.b1)
        return h @ self.w2 + self.b2

    def act(self, observation: np.ndarray) -> tuple[int, np.ndarray]:
        logits = self.logits(observation)
        # Softmax for a small local reduce (extra FLOPs, deterministic).
        shifted = logits - np.max(logits)
        exp = np.exp(shifted)
        probs = exp / np.sum(exp)
        action = int(np.argmax(probs))
        return action, logits

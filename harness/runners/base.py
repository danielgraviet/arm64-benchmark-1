"""Runner protocol: each backend exposes run_one(n, seed) -> result dict.

The suite actually types this as ``RunOne = Callable[[int, int], dict]`` and
receives a bound method / function from the factory. Class runners should still
match this Protocol so they remain drop-in compatible.

B3 (rl_rollout) may keep ``run_one`` as “one full episode” initially; a later
``run_episode`` API is optional if we need multi-step sandbox reuse.
"""

from __future__ import annotations

from typing import Any, Protocol


class Runner(Protocol):
    def run_one(self, n: int, seed: int) -> dict[str, Any]: ...

"""Runner protocol: each backend exposes run_one(n, seed) -> result dict.

The suite actually types this as ``RunOne = Callable[[int, int], dict]`` and
receives a bound method / function from the factory. Class runners should still
match this Protocol so they remain drop-in compatible.

B3 (``rl``) uses ``run_one`` as one full mocked episode (``n`` steps inside the
container). A later ``run_episode`` / sandbox-reuse API is optional Phase 2.
"""

from __future__ import annotations

from typing import Any, Protocol


class Runner(Protocol):
    def run_one(self, n: int, seed: int) -> dict[str, Any]: ...

"""Runner protocol: each backend exposes run_one(n, seed) -> result dict."""

from __future__ import annotations

from typing import Any, Protocol


class Runner(Protocol):
    def run_one(self, n: int, seed: int) -> dict[str, Any]: ...

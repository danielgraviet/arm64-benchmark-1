"""The hold suite must never leak its fleet.

Regression guard for the failure that repeatedly made benchmark hosts
unreachable: `timeout N ... main.py` fires SIGTERM, Python's default handler
exits without unwinding, the teardown never runs, and hundreds of sandboxes
stay resident with nothing left to delete them.
"""

from __future__ import annotations

import os
import signal
import threading

import pytest

from harness.common import run_hold_suite


class FakeSandbox:
    def __init__(self, idx: int) -> None:
        self.idx = idx


class FakeRunner:
    """Minimal runner double; records every sandbox created and deleted."""

    _episodes_per_sandbox = 1
    _arch = "test"
    _target = "test"
    _spec = None

    def __init__(self, explode: str | None = None) -> None:
        self.created: list[int] = []
        self.deleted: list[int] = []
        self._n = 0
        self._explode = explode
        self._lock = threading.Lock()

    def create_sandbox(self) -> FakeSandbox:
        with self._lock:
            self._n += 1
            idx = self._n
            self.created.append(idx)
        return FakeSandbox(idx)

    def exec_on_sandbox(self, sandbox, n, seed, episodes, cold_first=False):
        if self._explode == "exception":
            raise RuntimeError("workload blew up")
        if self._explode == "sigterm":
            os.kill(os.getpid(), signal.SIGTERM)
        return [{"latency_ms": 1.0, "exit_code": 0, "checksum": "abc", "episode_idx": 0}]

    def delete_sandbox(self, sandbox) -> None:
        with self._lock:
            self.deleted.append(sandbox.idx)


def _run(runner, tmp_path):
    return run_hold_suite(
        runner=runner,
        levels=[4],
        n=1,
        seed=1,
        output=tmp_path / "out.jsonl",
        meta={},
    )


def test_fleet_deleted_on_success(tmp_path):
    r = FakeRunner()
    _run(r, tmp_path)
    assert sorted(r.deleted) == sorted(r.created)


def test_fleet_deleted_when_exec_raises(tmp_path):
    r = FakeRunner(explode="exception")
    with pytest.raises(Exception):
        _run(r, tmp_path)
    assert sorted(r.deleted) == sorted(r.created), "fleet leaked on exec error"


def test_fleet_deleted_on_sigterm(tmp_path):
    """The case that actually bit us: `timeout` sends SIGTERM mid-run."""
    r = FakeRunner(explode="sigterm")
    previous = signal.getsignal(signal.SIGTERM)
    try:
        with pytest.raises(BaseException):
            _run(r, tmp_path)
        assert r.created, "no sandboxes were created"
        assert sorted(r.deleted) == sorted(r.created), "fleet leaked on SIGTERM"
    finally:
        signal.signal(signal.SIGTERM, previous)

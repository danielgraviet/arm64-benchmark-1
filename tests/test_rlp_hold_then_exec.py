"""Offline: hold-then-exec creates the fleet before any exec."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

from harness.common import run_hold_suite


class FakeHoldRunner:
    def __init__(self, *, fail_create_at: int | None = None) -> None:
        self.events: list[str] = []
        self._episodes_per_sandbox = 2
        self._target = "vera"
        self._spec = SimpleNamespace(id="rl")
        self._arch = "aarch64"
        self._n = 0
        self._fail_create_at = fail_create_at

    def create_sandbox(self) -> object:
        idx = self._n
        self._n += 1
        if self._fail_create_at is not None and idx == self._fail_create_at:
            self.events.append("create_fail")
            raise RuntimeError("boot failed")
        self.events.append("create")
        return object()

    def exec_on_sandbox(
        self,
        sandbox: object,
        n: int,
        seed: int,
        episodes: int,
        *,
        cold_first: bool,
    ) -> list[dict]:
        assert cold_first is False
        self.events.append("exec")
        return [
            {
                "latency_ms": 100.0 + i,
                "duration_ms": 90.0 + i,
                "exit_code": 0,
                "checksum": "abc",
                "cold": False,
                "fleet_hold": True,
                "episode_idx": i,
            }
            for i in range(episodes)
        ]

    def delete_sandbox(self, sandbox: object) -> None:
        self.events.append("delete")


def test_hold_then_exec_creates_before_any_exec(tmp_path: Path) -> None:
    runner = FakeHoldRunner()
    out = tmp_path / "hold.jsonl"
    run_hold_suite(
        levels=[3],
        n=64,
        seed=42,
        output=out,
        runner=runner,
    )
    creates = [i for i, e in enumerate(runner.events) if e == "create"]
    execs = [i for i, e in enumerate(runner.events) if e == "exec"]
    deletes = [i for i, e in enumerate(runner.events) if e == "delete"]
    assert len(creates) == 3
    assert len(execs) == 3
    assert len(deletes) == 3
    assert max(creates) < min(execs)
    assert max(execs) < min(deletes)


def test_hold_then_exec_summary_uses_exec_wall(tmp_path: Path) -> None:
    import json

    runner = FakeHoldRunner()
    out = tmp_path / "hold.jsonl"
    run_hold_suite(
        levels=[2],
        n=64,
        seed=42,
        output=out,
        runner=runner,
    )
    rows = [json.loads(line) for line in out.read_text().splitlines() if line]
    summary = next(r for r in rows if r["type"] == "summary")
    assert summary["runs"] == 4  # 2 sandboxes x 2 episodes
    assert summary["failures"] == 0
    assert "create_wall_s" in summary
    assert "exec_wall_s" in summary
    assert "delete_wall_s" in summary
    assert "throughput_including_create" in summary
    assert summary["p50_duration_ms"] > 0
    runs = [r for r in rows if r["type"] == "run"]
    assert all(r.get("cold") is False for r in runs)
    assert all(r.get("fleet_hold") is True for r in runs)


def test_hold_then_exec_records_create_failure(tmp_path: Path) -> None:
    import json

    runner = FakeHoldRunner(fail_create_at=0)
    out = tmp_path / "hold.jsonl"
    run_hold_suite(
        levels=[2],
        n=64,
        seed=42,
        output=out,
        runner=runner,
    )
    rows = [json.loads(line) for line in out.read_text().splitlines() if line]
    summary = next(r for r in rows if r["type"] == "summary")
    assert summary["failures"] >= 1
    fails = [r for r in rows if r["type"] == "run" and r.get("exit_code") != 0]
    assert fails
    assert "boot failed" in fails[0]["error"]


def test_hold_all_creates_fail_zero_exec_tput(tmp_path: Path) -> None:
    import json

    class Boom(FakeHoldRunner):
        def create_sandbox(self) -> object:
            self.events.append("create_fail")
            raise RuntimeError("boot failed")

    runner = Boom()
    out = tmp_path / "hold.jsonl"
    run_hold_suite(levels=[2], n=64, seed=42, output=out, runner=runner)
    summary = next(
        json.loads(line)
        for line in out.read_text().splitlines()
        if line and json.loads(line).get("type") == "summary"
    )
    assert summary["failures"] == 2
    assert summary["throughput_per_sec"] == 0.0
    assert summary["exec_wall_s"] < 0.1

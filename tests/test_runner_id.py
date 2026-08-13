"""Tests for Daytona runner-id fingerprint helpers."""

from __future__ import annotations

from types import SimpleNamespace

from harness.common import summarize
from harness.runner_id import parse_ifconfig_stdout, sdk_runner_id


def test_sdk_runner_id_from_attr() -> None:
    sandbox = SimpleNamespace(runner_id="runner-abc")
    assert sdk_runner_id(sandbox) == "runner-abc"


def test_sdk_runner_id_empty() -> None:
    assert sdk_runner_id(SimpleNamespace(runner_id=None)) is None
    assert sdk_runner_id(SimpleNamespace()) is None


def test_parse_ifconfig_ipv4() -> None:
    assert parse_ifconfig_stdout("203.0.113.10\n") == "203.0.113.10"


def test_parse_ifconfig_ipv6() -> None:
    assert parse_ifconfig_stdout("2001:db8::1") == "2001:db8::1"


def test_parse_ifconfig_rejects_garbage() -> None:
    assert parse_ifconfig_stdout("not an ip") is None
    assert parse_ifconfig_stdout("") is None


def test_summarize_distinct_runners() -> None:
    records = [
        {"latency_ms": 100.0, "exit_code": 0, "checksum": "a", "runner_id": "r1"},
        {"latency_ms": 110.0, "exit_code": 0, "checksum": "a", "runner_id": "r2"},
        {"latency_ms": 120.0, "exit_code": 0, "checksum": "a", "runner_id": "r1"},
    ]
    summary = summarize(records, wall_time_s=1.0)
    assert summary["distinct_runners"] == 2


def test_summarize_omits_runners_when_absent() -> None:
    records = [{"latency_ms": 100.0, "exit_code": 0, "checksum": "a"}]
    summary = summarize(records, wall_time_s=1.0)
    assert "distinct_runners" not in summary

"""Unit tests for RLP target vera wiring (no live API)."""

from __future__ import annotations

import os

import pytest

from harness.paths import result_series_name
from harness.regions import (
    resolve_rlp_client_config,
    resolve_rlp_cpu_arch,
    resolve_rlp_cpu_type,
    resolve_rlp_mode,
    resolve_rlp_toolbox_url,
    validate_rlp_target,
)


def test_result_series_rlp_vera() -> None:
    assert result_series_name("rlp", "vera") == "rlp-vera"
    assert result_series_name("rlp", "arm64-test-1") == "rlp-arm64"
    assert result_series_name("rlp", None) == "rlp-x86"


def test_result_series_daytona_graviton5() -> None:
    assert result_series_name("daytona", "us-east-1-arm") == "daytona-graviton5"
    assert result_series_name("daytona-vm", "us-east-1-arm") == "daytona-graviton5"
    assert result_series_name("daytona", None) == "daytona"
    assert result_series_name("daytona", "us") == "daytona"


def test_vera_cpu_type_mode_arch() -> None:
    assert resolve_rlp_cpu_arch("vera") == "arm64"
    assert resolve_rlp_cpu_type("vera") == "vera"
    assert resolve_rlp_mode("vera") == "dedicated"
    assert resolve_rlp_cpu_type("arm64-test-1") is None
    assert resolve_rlp_mode("arm64-test-1") is None


def test_validate_vera_target() -> None:
    validate_rlp_target("vera")
    with pytest.raises(ValueError, match="Unknown RLP target"):
        validate_rlp_target("vera-typo")


def test_resolve_rlp_client_config_vera(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("VERA_RLP_API_URL", "http://127.0.0.1:8088")
    monkeypatch.setenv("VERA_RLP_API_KEY", "rlpv_test")
    monkeypatch.delenv("VERA_RLP_TOOLBOX_URL", raising=False)
    cfg = resolve_rlp_client_config("vera")
    assert cfg.api_url == "http://127.0.0.1:8088"
    assert cfg.api_key == "rlpv_test"
    assert cfg.toolbox_url == "http://127.0.0.1:9000/toolbox"
    assert cfg.target == "vera"
    assert cfg.region_routing is False


def test_resolve_rlp_client_config_vera_toolbox_env(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("VERA_RLP_API_URL", "http://127.0.0.1:8088")
    monkeypatch.setenv("VERA_RLP_API_KEY", "rlpv_test")
    monkeypatch.setenv("VERA_RLP_TOOLBOX_URL", "http://127.0.0.1:9001/toolbox")
    cfg = resolve_rlp_client_config("vera")
    assert cfg.toolbox_url == "http://127.0.0.1:9001/toolbox"


def test_resolve_rlp_client_config_vera_missing_url(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("VERA_RLP_API_URL", raising=False)
    monkeypatch.setenv("VERA_RLP_API_KEY", "rlpv_test")
    with pytest.raises(ValueError, match="VERA_RLP_API_URL"):
        resolve_rlp_client_config("vera")


def test_toolbox_cli_override() -> None:
    assert (
        resolve_rlp_toolbox_url("vera", "http://custom:9000/toolbox")
        == "http://custom:9000/toolbox"
    )

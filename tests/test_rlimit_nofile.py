"""Offline: harness.rlimit_nofile must raise a 1024 soft cap and refuse a too-low ladder."""

from __future__ import annotations

import resource

import pytest

from harness.rlimit_nofile import OVERHEAD, raise_nofile, require_nofile


def test_raise_nofile_lifts_1024_soft_when_hard_allows(monkeypatch):
    state = {"soft": 1024, "hard": 1_048_576}

    def fake_get(which):
        assert which == resource.RLIMIT_NOFILE
        return state["soft"], state["hard"]

    def fake_set(which, limits):
        assert which == resource.RLIMIT_NOFILE
        soft, hard = limits
        assert hard == state["hard"]
        state["soft"] = soft

    monkeypatch.setattr(resource, "getrlimit", fake_get)
    monkeypatch.setattr(resource, "setrlimit", fake_set)

    info = raise_nofile()
    assert info["nofile_soft_before"] == 1024
    assert info["nofile_soft"] == 1_048_576
    assert info["nofile_hard"] == 1_048_576
    assert info["nofile_raised"] is True
    assert info["nofile_error"] is None


def test_raise_nofile_does_not_lower_an_already_high_soft(monkeypatch):
    state = {"soft": 1_048_576, "hard": 1_048_576}

    def fake_get(which):
        return state["soft"], state["hard"]

    def fake_set(which, limits):  # pragma: no cover
        raise AssertionError("must not lower an already-raised soft limit")

    monkeypatch.setattr(resource, "getrlimit", fake_get)
    monkeypatch.setattr(resource, "setrlimit", fake_set)

    info = raise_nofile()
    assert info["nofile_raised"] is False
    assert info["nofile_soft"] == 1_048_576


def test_raise_nofile_caps_at_hard(monkeypatch):
    state = {"soft": 1024, "hard": 4096}

    def fake_get(which):
        return state["soft"], state["hard"]

    def fake_set(which, limits):
        state["soft"], state["hard"] = limits

    monkeypatch.setattr(resource, "getrlimit", fake_get)
    monkeypatch.setattr(resource, "setrlimit", fake_set)

    info = raise_nofile(want=1_048_576)
    assert info["nofile_soft"] == 4096


def test_require_nofile_refuses_1024_when_hard_cannot_cover_c2000(monkeypatch):
    state = {"soft": 1024, "hard": 1024}

    def fake_get(which):
        return state["soft"], state["hard"]

    def fake_set(which, limits):
        state["soft"], state["hard"] = limits

    monkeypatch.setattr(resource, "getrlimit", fake_get)
    monkeypatch.setattr(resource, "setrlimit", fake_set)

    with pytest.raises(RuntimeError, match="Too many open files"):
        require_nofile(2000)


def test_require_nofile_accepts_c2000_after_raise(monkeypatch):
    state = {"soft": 1024, "hard": 1_048_576}

    def fake_get(which):
        return state["soft"], state["hard"]

    def fake_set(which, limits):
        state["soft"], state["hard"] = limits

    monkeypatch.setattr(resource, "getrlimit", fake_get)
    monkeypatch.setattr(resource, "setrlimit", fake_set)

    info = require_nofile(2000)
    assert info["nofile_soft"] == 1_048_576
    assert info["nofile_need"] == 2000 + OVERHEAD
    assert info["nofile_max_concurrency"] == 2000

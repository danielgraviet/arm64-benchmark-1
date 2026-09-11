"""Offline: create-ready fleet script matches Vera's JSONL schema and client caps."""

from __future__ import annotations

import resource

from scripts.rlp_light_create_fleet import (
    VERA_CREATE_READY_NOFILE,
    _raise_nofile_to_vera,
    _ulimit_nofile,
)


def test_raise_nofile_lifts_1024_to_vera_65536(monkeypatch):
    state = {"soft": 1024, "hard": 1_048_576}

    def fake_get(which):
        assert which == resource.RLIMIT_NOFILE
        return state["soft"], state["hard"]

    def fake_set(which, limits):
        assert which == resource.RLIMIT_NOFILE
        state["soft"], state["hard"] = limits

    monkeypatch.setattr(resource, "getrlimit", fake_get)
    monkeypatch.setattr(resource, "setrlimit", fake_set)

    _raise_nofile_to_vera()
    soft, hard = _ulimit_nofile()
    assert soft == VERA_CREATE_READY_NOFILE
    assert hard == 1_048_576


def test_raise_nofile_pins_1m_soft_down_to_vera_65536(monkeypatch):
    state = {"soft": 1_048_576, "hard": 1_048_576}

    def fake_get(which):
        return state["soft"], state["hard"]

    def fake_set(which, limits):
        state["soft"], state["hard"] = limits

    monkeypatch.setattr(resource, "getrlimit", fake_get)
    monkeypatch.setattr(resource, "setrlimit", fake_set)

    _raise_nofile_to_vera()
    soft, _hard = _ulimit_nofile()
    assert soft == VERA_CREATE_READY_NOFILE

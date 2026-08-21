"""Offline: harness.rlp_client_tuning must widen the SDK pool and temper polls.

The plateau it fixes (vera, 176 workers, ~1.1s episodes, guest p50 constant):
pool=100 -> 19.5-82.3/s depending on RTT; pool=600 co-located -> 128.9/s with
wall == guest + RTT. Raising the pool without tempering wait_until_started
polls made ladders WORSE (phoenix: 24/s -> 9.8/s), so both patches ship together.
"""

from __future__ import annotations

import pytest

from harness import rlp_client_tuning


@pytest.fixture(autouse=True)
def applied():
    rlp_client_tuning.apply()  # idempotent


def test_http_client_pool_is_widened():
    from rlp.http import HttpClient

    c = HttpClient("http://example.invalid", "k")
    pool = c._client._transport._pool
    assert pool._max_connections == 512  # RLP_HTTP_MAX_CONNECTIONS default


def test_apply_is_idempotent():
    rlp_client_tuning.apply()
    rlp_client_tuning.apply()
    from rlp.http import HttpClient

    c = HttpClient("http://example.invalid", "k")
    # A double-wrapped __init__ would rebuild the client twice; the pool must
    # still be the configured one and the client usable.
    assert c._client._transport._pool._max_connections == 512


def test_wait_until_started_polls_back_off(monkeypatch):
    from rlp.sandbox import Sandbox

    sleeps: list[float] = []
    monkeypatch.setattr(rlp_client_tuning.time, "sleep", sleeps.append)

    class Fake:
        id = "vm_1"
        state = "creating"
        error_reason = None
        _n = 0

        def refresh_data(self):
            Fake._n += 1
            if Fake._n >= 8:
                self.state = "started"

    Sandbox.wait_until_started(Fake(), timeout=60)

    assert sleeps[0] == pytest.approx(0.25)   # not the SDK's 0.1s
    assert max(sleeps) <= 2.0                 # ceiling
    assert sleeps == sorted(sleeps)           # monotonic backoff
    # Stock SDK cadence for the same 7 waits: 7 x 0.1s = 0.7s of sleep -> 10 Hz.
    # Tempered: first ~7 polls span >= 4x that, i.e. ~4x fewer polls/sec fleetwide.
    assert sum(sleeps) >= 2.5


def test_wait_until_started_error_state_still_raises():
    from rlp.errors import DaytonaError
    from rlp.sandbox import Sandbox

    class Broken:
        id = "vm_2"
        state = "error"
        error_reason = "boot failed"

        def refresh_data(self):
            pass

    with pytest.raises(DaytonaError, match="failed to start"):
        Sandbox.wait_until_started(Broken(), timeout=60)

"""Offline: ``resolve_boot_image`` must not region-pin a native snapshot.

A native disk snapshot is a REGIONAL artifact (its erofs manifest lives on one
region's NFS CAS) but ``GET /snapshots`` is a management surface bound to
``RLP_API_URL``. Resolving the friendly name to ``manifest_name`` client-side
and booting that in another region hands the runner a ``snap-<uuid>`` the target
NFS has never seen -> ``manifest "snap-..." not found on NFS``.

So the boot image for a friendly name must stay the *name*, tagged as a snapshot
source, and be resolved API-side in the target region.
"""

from __future__ import annotations

import pytest
from rlp.errors import DaytonaError

from harness.rlp_snapshots import is_registry_image_ref, resolve_boot_image


class FakeApi:
    def __init__(self, payload: dict) -> None:
        self._payload = payload

    def get(self, path: str) -> "FakeApi":
        assert path == "/snapshots"
        return self

    def json(self) -> dict:
        return self._payload


class FakeClient:
    """Stands in for ``rlp.Daytona`` (only ``_api.get('/snapshots')`` is used)."""

    def __init__(self, snapshots: list[dict]) -> None:
        self._api = FakeApi({"snapshots": snapshots})


READY = [
    {
        "name": "vera-evals-benchmark",
        "status": "ready",
        "manifest_name": "snap-6daae79a-009d-4789-9ada-41e1472c3936",
    }
]


def test_friendly_name_resolves_to_snapshot_source_not_manifest() -> None:
    got = resolve_boot_image(FakeClient(READY), "vera-evals-benchmark")
    assert got == {"type": "snapshot", "name": "vera-evals-benchmark"}


def test_manifest_name_is_never_leaked_into_the_boot_image() -> None:
    """The regression guard: a `snap-<uuid>` from one cell must not become the
    boot image for a create in another."""
    got = resolve_boot_image(FakeClient(READY), "vera-evals-benchmark")
    assert "snap-6daae79a-009d-4789-9ada-41e1472c3936" not in repr(got)


def test_explicit_manifest_name_passes_through() -> None:
    """An operator naming a manifest outright still gets the raw NFS lookup."""
    got = resolve_boot_image(FakeClient(READY), "snap-6daae79a-0000")
    assert got == "snap-6daae79a-0000"


@pytest.mark.parametrize(
    "ref",
    ["dtgraviet/vera-agent-benchmark-rl:latest", "python:3.13-slim", "sha256:abc123"],
)
def test_registry_refs_pass_through(ref: str) -> None:
    assert is_registry_image_ref(ref)
    assert resolve_boot_image(FakeClient(READY), ref) == ref


def test_missing_snapshot_error_names_both_causes() -> None:
    """A miss is ambiguous (never built vs. wrong cell) — say both."""
    with pytest.raises(DaytonaError) as e:
        resolve_boot_image(FakeClient([]), "vera-typo", target="us-phoenix-1")
    msg = str(e.value)
    assert "build_rlp_snapshot.py" in msg
    assert "RLP_API_URL" in msg
    assert "us-phoenix-1" in msg


def test_not_ready_snapshot_is_rejected() -> None:
    pending = [{"name": "vera-x", "status": "capturing", "manifest_name": None}]
    with pytest.raises(DaytonaError, match="not ready"):
        resolve_boot_image(FakeClient(pending), "vera-x")

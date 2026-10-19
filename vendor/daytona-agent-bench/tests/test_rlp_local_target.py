"""Offline: --target local is the only RLP target in this pack."""

from __future__ import annotations

import pytest

from harness.regions import LOCAL_TARGET, validate_rlp_target


def test_local_target_is_valid() -> None:
    validate_rlp_target(LOCAL_TARGET)
    validate_rlp_target(None)


def test_unknown_target_is_rejected() -> None:
    with pytest.raises(ValueError, match="local"):
        validate_rlp_target("redswitches")

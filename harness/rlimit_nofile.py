"""Raise RLIMIT_NOFILE so dense ladders are not the distro login-shell default.

The 2026-09-06 Zen5 9575F dense ladder on rs-vl-us-15 inherited
``ulimit -Sn = 1024`` from an interactive root login. systemd ``rlp-*.service``
already had ``LimitNOFILE=1048576`` and the hard limit was 1048576. Successful
sandbox-equivalents plateaued at 1011–1019 (1024 minus stdio, the JSONL handle,
and the client's own sockets). 96% of failures were ``[Errno 24] Too many open
files`` inside the harness client, not the EPYC 9575F.

Call ``require_nofile(max_concurrency)`` once at process start, before any
sandbox creates. Prefer the hard limit. Never lower an already-raised soft
limit. Record the before/after values in JSONL meta.
"""

from __future__ import annotations

import resource
from typing import Any

# Match systemd LimitNOFILE on the cells. Three orders of magnitude inside
# the typical 1048576 hard cap; enough for a 2000-wide hold-then-exec fleet.
DEFAULT_SOFT = 1_048_576
# stdio + JSONL + a handful of client sockets. Empirical: 1024 - 1011..1019.
OVERHEAD = 64


def current() -> tuple[int, int]:
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    return int(soft), int(hard)


def _finite(value: int) -> bool:
    return value != resource.RLIM_INFINITY


def raise_nofile(*, want: int | None = None) -> dict[str, Any]:
    """Raise the soft NOFILE limit toward ``min(want or DEFAULT_SOFT, hard)``.

    Returns a JSONL-safe dict. Does not raise on ``setrlimit`` failure; the
    caller decides whether the resulting soft limit is enough.
    """
    before_soft, hard = current()
    if not _finite(hard):
        target = want or DEFAULT_SOFT
    else:
        target = min(want or DEFAULT_SOFT, hard)

    after_soft = before_soft
    raised = False
    error: str | None = None
    if _finite(before_soft) and before_soft < target:
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
            after_soft, hard = current()
            raised = after_soft > before_soft
        except (ValueError, OSError) as exc:
            error = f"{type(exc).__name__}: {exc}"
            after_soft, hard = current()

    return {
        "nofile_soft_before": before_soft,
        "nofile_soft": after_soft,
        "nofile_hard": hard,
        "nofile_raised": raised,
        "nofile_error": error,
    }


def require_nofile(
    max_concurrency: int,
    *,
    overhead: int = OVERHEAD,
    want: int | None = None,
) -> dict[str, Any]:
    """Raise NOFILE, then fail if the soft limit still cannot cover the ladder.

    ``max_concurrency`` is ``max(--levels)``. A 1024 distro default will not
    survive a 1056–2000 wave; aborting here is cheaper than quoting the FD wall
    as silicon.
    """
    if max_concurrency < 1:
        raise ValueError(f"max_concurrency must be >= 1, got {max_concurrency}")
    info = raise_nofile(want=want)
    need = max_concurrency + overhead
    soft = int(info["nofile_soft"])
    if _finite(soft) and soft < need:
        hard = info["nofile_hard"]
        raise RuntimeError(
            f"NOFILE soft limit is {soft} after raise (hard {hard}); "
            f"need >= {need} for concurrency {max_concurrency}. "
            f"A 1024 distro default plateaus near {1024 - overhead} sandboxes "
            f"with [Errno 24] Too many open files. Raise with "
            f"`ulimit -n {need}` (or systemd LimitNOFILE) before the ladder."
        )
    info["nofile_need"] = need
    info["nofile_max_concurrency"] = max_concurrency
    return info

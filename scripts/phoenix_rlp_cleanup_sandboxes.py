"""Delete all live sandboxes on the Phoenix (Zen 5) RLP cell.

The GET /vms list is paginated (~100 per page). ``Daytona.list()`` only returns
the first page, so this script walks ``next_cursor`` until exhausted, then
DELETEs every VM whose status is not already ``deleted``.

Requires ``PHOENIX_RLP_API_KEY`` (or default ``RLP_API_KEY``) in ``.env``.
API URL defaults to the Phoenix cell via ``harness.regions``.

Examples::

    uv run python scripts/phoenix_rlp_cleanup_sandboxes.py
    uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --dry-run
    uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --workers 16
"""

from __future__ import annotations

import argparse
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any
from urllib.parse import quote

from dotenv import load_dotenv
from rlp import Daytona

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from harness.regions import PHOENIX_TARGET, resolve_rlp_client_config  # noqa: E402


def fetch_all_vms(api: Any, *, verbose: bool = True) -> list[dict[str, Any]]:
    """Walk paginated GET /vms until ``next_cursor`` is empty."""
    all_vms: list[dict[str, Any]] = []
    cursor: str | None = None
    page = 0
    while True:
        path = "/vms" if not cursor else f"/vms?cursor={quote(cursor, safe='')}"
        data = api.get(path).json()
        batch = data.get("vms", [])
        page += 1
        all_vms.extend(batch)
        cursor = data.get("next_cursor")
        if verbose:
            print(
                f"page {page}: +{len(batch)} (total {len(all_vms)}) "
                f"next_cursor={'yes' if cursor else 'no'}",
                flush=True,
            )
        if not cursor or not batch:
            break
    return all_vms


def is_live(vm: dict[str, Any]) -> bool:
    return (vm.get("status") or "").lower() != "deleted"


def delete_vm(api: Any, vm: dict[str, Any]) -> tuple[str, str | None]:
    vid = vm["id"]
    if not is_live(vm):
        return vid, "skip"
    try:
        api.delete(f"/vms/{vid}")
        return vid, None
    except Exception as exc:  # noqa: BLE001
        return vid, str(exc)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Delete all live sandboxes on the Phoenix (Zen 5) RLP cell."
    )
    parser.add_argument(
        "--target",
        default=PHOENIX_TARGET,
        help=f"RLP target (default: {PHOENIX_TARGET})",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=32,
        help="Parallel delete workers (default: 32)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List live sandboxes only; do not delete",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress per-page fetch logging",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.workers < 1:
        raise SystemExit("--workers must be >= 1")

    load_dotenv(ROOT / ".env")
    config = resolve_rlp_client_config(args.target)
    client = Daytona(config)
    api = client._api

    print(f"target={args.target!r} api_url={config.api_url!r}", flush=True)

    vms = fetch_all_vms(api, verbose=not args.quiet)
    live = [v for v in vms if is_live(v)]
    print(
        f"listed={len(vms)} live={len(live)} "
        f"already_deleted={len(vms) - len(live)}",
        flush=True,
    )

    if not live:
        print("no live sandboxes to delete", flush=True)
        return

    if args.dry_run:
        print("dry-run: would delete", len(live), "sandboxes", flush=True)
        for vm in live[:20]:
            print(f"  {vm['id']} status={vm.get('status')}", flush=True)
        if len(live) > 20:
            print(f"  … and {len(live) - 20} more", flush=True)
        return

    deleted = 0
    failed = 0
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(delete_vm, api, vm) for vm in live]
        for fut in as_completed(futures):
            vid, err = fut.result()
            if err == "skip":
                continue
            if err:
                failed += 1
                if failed <= 10:
                    print(f"FAIL {vid}: {err[:120]}", flush=True)
            else:
                deleted += 1

    print(f"deleted={deleted} failed={failed}", flush=True)

    if not args.quiet:
        print("--- recount ---", flush=True)
    vms_after = fetch_all_vms(api, verbose=not args.quiet)
    live_after = [v for v in vms_after if is_live(v)]
    print(
        f"after: listed={len(vms_after)} live={len(live_after)}",
        flush=True,
    )

    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

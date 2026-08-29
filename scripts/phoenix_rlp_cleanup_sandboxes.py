#!/usr/bin/env python3
"""Delete leftover benchmark sandboxes on the Phoenix (us-phoenix-1) cell.

Ladder runs that die (laptop client, Ctrl-C, network drop) leave live VMs
behind; they keep holding runner capacity and the next ladder then fails with
``create job not picked up by any runner within 60s (no matching capacity)``.

Run this from the Phoenix cell API host before starting a ladder:

    ./.venv/bin/python scripts/phoenix_rlp_cleanup_sandboxes.py            # dry run summary + delete
    ./.venv/bin/python scripts/phoenix_rlp_cleanup_sandboxes.py --dry-run  # list only

By default only sandboxes whose ``image_ref`` contains the benchmark image are
removed, so unrelated VMs on the cell are left alone.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_API = "http://127.0.0.1:8088"
DEFAULT_IMAGE_MATCH = "vera-agent-benchmark"
LIVE_STATES = ("running", "starting", "pending", "creating", "paused", "stopped")


def load_env() -> None:
    env_path = ROOT / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())


def request(method: str, url: str, key: str, timeout: float = 30.0):
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()
        return resp.status, body


def list_vms(api: str, key: str, image_match: str, states: tuple[str, ...]) -> list[dict]:
    out: list[dict] = []
    cursor = None
    pages = 0
    while True:
        url = f"{api}/vms?limit=200" + (f"&cursor={cursor}" if cursor else "")
        _, body = request("GET", url, key)
        data = json.loads(body)
        vms = data.get("vms") or []
        for vm in vms:
            if vm.get("status") not in states:
                continue
            if image_match and image_match not in (vm.get("image_ref") or ""):
                continue
            out.append(vm)
        cursor = data.get("next_cursor")
        pages += 1
        if not cursor or not vms:
            break
        if pages > 500:
            print("! pagination guard hit", file=sys.stderr)
            break
    return out


def delete_one(api: str, key: str, vm_id: str, attempts: int = 3) -> tuple[str, bool, str]:
    for i in range(attempts):
        try:
            status, _ = request("DELETE", f"{api}/vms/{vm_id}", key, timeout=60.0)
            if status in (200, 202, 204, 404):
                return vm_id, True, str(status)
            last = str(status)
        except urllib.error.HTTPError as exc:  # noqa: PERF203
            if exc.code in (404, 409, 410):
                return vm_id, True, str(exc.code)
            last = f"HTTP {exc.code}"
        except Exception as exc:  # noqa: BLE001
            last = type(exc).__name__
        time.sleep(0.5 * (i + 1))
    return vm_id, False, last


def main() -> int:
    load_env()
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default=os.environ.get("RLP_API_URL") or DEFAULT_API)
    ap.add_argument("--image-match", default=DEFAULT_IMAGE_MATCH,
                    help="only delete sandboxes whose image_ref contains this ('' = all)")
    ap.add_argument("--workers", type=int, default=48)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    key = os.environ.get("RLP_API_KEY", "").strip()
    if not key:
        print("RLP_API_KEY not set (expected in .env)", file=sys.stderr)
        return 2

    vms = list_vms(args.api, key, args.image_match, LIVE_STATES)
    by_state: dict[str, int] = {}
    for vm in vms:
        by_state[vm.get("status", "?")] = by_state.get(vm.get("status", "?"), 0) + 1
    print(f"api={args.api} image_match={args.image_match!r}")
    print(f"leftover sandboxes: {len(vms)} {by_state}")
    if not vms:
        return 0
    if args.dry_run:
        for vm in vms[:10]:
            print("  ", vm["id"], vm.get("status"), vm.get("created_at"))
        print("  ... (dry run, nothing deleted)")
        return 0

    t0 = time.time()
    ok = 0
    fail: list[tuple[str, str]] = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = [pool.submit(delete_one, args.api, key, vm["id"]) for vm in vms]
        for n, fut in enumerate(futs, 1):
            vm_id, good, info = fut.result()
            if good:
                ok += 1
            else:
                fail.append((vm_id, info))
            if n % 250 == 0:
                print(f"  {n}/{len(vms)} deleted={ok} failed={len(fail)} "
                      f"({time.time() - t0:.0f}s)", flush=True)

    print(f"done: deleted={ok} failed={len(fail)} in {time.time() - t0:.0f}s")
    for vm_id, info in fail[:20]:
        print("  FAIL", vm_id, info)
    return 0 if not fail else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Upload local ``data/`` JSONL results to S3 (off-machine backup).

Uses the default AWS credential chain (env keys, ``~/.aws/credentials``,
``AWS_PROFILE``, etc.). Bucket from ``--bucket`` or ``VERA_DATA_S3_BUCKET``.

Examples::

    # one-shot sync (mirrors data/ under s3://bucket/arm64-benchmark-1/data/)
    uv run scripts/upload_data_s3.py --bucket my-backup-bucket

    # dated snapshot so a later sync cannot overwrite this point-in-time
    uv run scripts/upload_data_s3.py --bucket my-backup-bucket --snapshot

    # dry run
    uv run scripts/upload_data_s3.py --bucket my-backup-bucket --dry-run

    export VERA_DATA_S3_BUCKET=my-backup-bucket
    uv run scripts/upload_data_s3.py --snapshot
"""

from __future__ import annotations

import argparse
import mimetypes
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from dotenv import load_dotenv

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from harness.paths import ROOT

DEFAULT_PREFIX = "arm64-benchmark-1"
DATA_DIR = ROOT / "data"


def _s3_client(*, region: str | None, profile: str | None):
    try:
        import boto3
    except ImportError as exc:  # pragma: no cover
        raise SystemExit(
            "boto3 is required. Install with: uv add boto3"
        ) from exc

    session_kwargs: dict = {}
    if profile:
        session_kwargs["profile_name"] = profile
    session = boto3.Session(**session_kwargs)
    return session.client("s3", region_name=region)


def iter_data_files(root: Path) -> list[Path]:
    if not root.is_dir():
        return []
    return sorted(p for p in root.rglob("*") if p.is_file())


def object_key(local: Path, *, data_root: Path, prefix: str) -> str:
    rel = local.relative_to(data_root).as_posix()
    base = prefix.strip("/")
    return f"{base}/data/{rel}" if base else f"data/{rel}"


def upload(
    *,
    bucket: str,
    prefix: str,
    dry_run: bool,
    region: str | None,
    profile: str | None,
) -> int:
    files = iter_data_files(DATA_DIR)
    if not files:
        print(f"No files under {DATA_DIR} — nothing to upload.")
        return 0

    client = None if dry_run else _s3_client(region=region, profile=profile)
    uploaded = 0
    for path in files:
        key = object_key(path, data_root=DATA_DIR, prefix=prefix)
        uri = f"s3://{bucket}/{key}"
        size = path.stat().st_size
        if dry_run:
            print(f"DRY-RUN  {path.relative_to(ROOT)}  ->  {uri}  ({size} bytes)")
            uploaded += 1
            continue
        assert client is not None
        content_type, _ = mimetypes.guess_type(path.name)
        extra = {"ContentType": content_type or "application/octet-stream"}
        client.upload_file(
            str(path),
            bucket,
            key,
            ExtraArgs=extra,
        )
        print(f"OK  {path.relative_to(ROOT)}  ->  {uri}")
        uploaded += 1
    return uploaded


def main() -> None:
    load_dotenv(ROOT / ".env")
    parser = argparse.ArgumentParser(
        description="Backup data/ JSONL results to an S3 bucket"
    )
    parser.add_argument(
        "--bucket",
        default=os.environ.get("VERA_DATA_S3_BUCKET"),
        help="S3 bucket name (or set VERA_DATA_S3_BUCKET)",
    )
    parser.add_argument(
        "--prefix",
        default=os.environ.get("VERA_DATA_S3_PREFIX", DEFAULT_PREFIX),
        help=f"Key prefix under the bucket (default: {DEFAULT_PREFIX})",
    )
    parser.add_argument(
        "--snapshot",
        action="store_true",
        help=(
            "Upload under prefix/backups/<UTC-stamp>/ so this point-in-time "
            "is not overwritten by a later plain sync"
        ),
    )
    parser.add_argument(
        "--region",
        default=os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION"),
        help="AWS region (optional; default from env / config)",
    )
    parser.add_argument(
        "--profile",
        default=os.environ.get("AWS_PROFILE"),
        help="AWS shared-credentials profile name (optional)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List planned uploads without calling S3",
    )
    args = parser.parse_args()

    if not args.bucket:
        parser.error(
            "Pass --bucket or set VERA_DATA_S3_BUCKET in the environment / .env"
        )

    prefix = args.prefix.strip("/")
    if args.snapshot:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        prefix = f"{prefix}/backups/{stamp}" if prefix else f"backups/{stamp}"

    print(f"source={DATA_DIR}")
    print(f"dest=s3://{args.bucket}/{prefix}/data/")
    if args.dry_run:
        print("mode=dry-run")

    n = upload(
        bucket=args.bucket,
        prefix=prefix,
        dry_run=args.dry_run,
        region=args.region,
        profile=args.profile,
    )
    print(f"Done: {n} file(s).")


if __name__ == "__main__":
    main()

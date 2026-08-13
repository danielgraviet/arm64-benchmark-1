"""Deterministic sandbox-disk stress: sequential write/fsync/read + small files.

``--n`` scales both axes:
  sequential bytes = n * 1 MiB
  small files      = n * FILES_PER_N

Uses a fixed 1 MiB recycled buffer so this stays a disk probe, not a RAM one.
Work runs under a TemporaryDirectory (cleaned up before return).
"""

from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path
from typing import Any

MIB = 1024 * 1024
CHUNK_SIZE = MIB  # 1 MiB write/read chunk
FILES_PER_N = 64
# Small-file payload: 1–4 KiB depending on (seed, index).
SMALL_BASE = 1024


def bytes_for_n(n: int) -> int:
    if n < 1:
        raise ValueError(f"n must be >= 1, got {n}")
    return n * MIB


def files_for_n(n: int) -> int:
    if n < 1:
        raise ValueError(f"n must be >= 1, got {n}")
    return n * FILES_PER_N


def _make_chunk(seed: int, index: int) -> bytes:
    """Deterministic 1 MiB pattern (4-byte repeating word)."""
    word = (seed * 1_315_423_911 + index * 2_654_435_761) & 0xFFFFFFFF
    return word.to_bytes(4, "little") * (CHUNK_SIZE // 4)


def _small_content(seed: int, index: int) -> bytes:
    size = SMALL_BASE * (1 + ((seed + index) % 4))  # 1–4 KiB
    word = (seed * 2654435761 + index * 40503) & 0xFFFFFFFF
    pattern = word.to_bytes(4, "little")
    reps = (size + 3) // 4
    return (pattern * reps)[:size]


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def run(n: int, seed: int) -> dict[str, Any]:
    """Execute sequential + small-file disk stress; return deterministic digests."""
    target = bytes_for_n(n)
    n_files = files_for_n(n)

    with tempfile.TemporaryDirectory(prefix="vera-disk-") as tmp:
        root = Path(tmp)
        seq_path = root / "seq.bin"
        small_dir = root / "small"
        small_dir.mkdir()

        # --- sequential write + fsync ---
        write_hasher = hashlib.sha256()
        written = 0
        idx = 0
        with seq_path.open("wb") as f:
            while written < target:
                chunk = _make_chunk(seed, idx)
                to_write = min(CHUNK_SIZE, target - written)
                data = chunk[:to_write]
                f.write(data)
                write_hasher.update(data)
                written += to_write
                idx += 1
            f.flush()
            os.fsync(f.fileno())
        seq_sha256 = write_hasher.hexdigest()

        # --- sequential read-verify ---
        read_hasher = hashlib.sha256()
        read_bytes = 0
        with seq_path.open("rb") as f:
            while True:
                data = f.read(CHUNK_SIZE)
                if not data:
                    break
                read_hasher.update(data)
                read_bytes += len(data)
        if read_hasher.hexdigest() != seq_sha256:
            raise RuntimeError("sequential read digest mismatch")
        if read_bytes != written:
            raise RuntimeError(
                f"sequential byte mismatch: wrote {written}, read {read_bytes}"
            )

        # --- small-file storm ---
        small_hasher = hashlib.sha256()
        files_bytes = 0
        for i in range(n_files):
            content = _small_content(seed, i)
            (small_dir / f"{i:06d}.dat").write_bytes(content)
            small_hasher.update(content)
            files_bytes += len(content)
        _fsync_dir(small_dir)

        # Sample read (~16 points across the set), then unlink all.
        sample_hasher = hashlib.sha256()
        sample_bytes = 0
        step = max(1, n_files // 16)
        for i in range(0, n_files, step):
            data = (small_dir / f"{i:06d}.dat").read_bytes()
            sample_hasher.update(data)
            sample_bytes += len(data)

        for i in range(n_files):
            (small_dir / f"{i:06d}.dat").unlink()

        return {
            "bytes_written": written + files_bytes,
            "bytes_read": read_bytes + sample_bytes,
            "files_touched": n_files,
            "seq_bytes": written,
            "seq_sha256": seq_sha256,
            "small_content_sha256": small_hasher.hexdigest(),
            "sample_sha256": sample_hasher.hexdigest(),
            "mib": n,
            "seed": seed,
        }

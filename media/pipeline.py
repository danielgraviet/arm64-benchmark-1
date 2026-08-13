"""Deterministic synthetic-frame → FFmpeg h.264 → decode-verify pipeline.

``--n`` scales frame count linearly (``frames = n * FRAMES_PER_N``). Timed work
covers generate + encode + decode verify — the Chart C bandwidth spike.

Frames are piped to ffmpeg stdin (never a multi-GB raw file on disk) so Chart C
``--n 40`` fits Daytona / sandbox disk limits.
"""

from __future__ import annotations

import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path

WIDTH = 640
HEIGHT = 360
FPS = 30
FRAMES_PER_N = 90  # --n 1 ≈ 3s @ 30fps; Chart C uses larger n for multi-second duration_ms
PIXEL_BYTES = WIDTH * HEIGHT * 3  # rgb24


def frame_count(n: int) -> int:
    if n < 1:
        raise ValueError(f"n must be >= 1, got {n}")
    return n * FRAMES_PER_N


def _require_ffmpeg() -> str:
    path = shutil.which("ffmpeg")
    if not path:
        raise RuntimeError(
            "ffmpeg not found on PATH; install ffmpeg for the media benchmark"
        )
    return path


def _make_frame(seed: int, frame_idx: int) -> bytes:
    """One rgb24 frame: full-size memory traffic, but compressible for ffmpeg.

    Horizontal gradients (not white noise) keep Chart C ``--n 40`` outputs
    small enough for Daytona disk while still moving ~frames×W×H×3 bytes.
    """
    row = bytearray(WIDTH * 3)
    for x in range(WIDTH):
        v = (x + seed + frame_idx) & 0xFF
        i = x * 3
        row[i] = v
        row[i + 1] = (v * 3 + frame_idx) & 0xFF
        row[i + 2] = (v + seed) & 0xFF
    return bytes(row) * HEIGHT


def _run(cmd: list[str], *, stdin: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    proc = subprocess.run(
        cmd,
        input=stdin,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        err = (proc.stderr or b"").decode("utf-8", errors="replace").strip()
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(cmd[:6])}…\n{err}"
        )
    return proc


def encode_h264_piped(
    ffmpeg: str,
    out_path: Path,
    *,
    n: int,
    seed: int,
) -> tuple[int, str]:
    """Generate frames, pipe rgb24 to ffmpeg stdin; return (frames, input_sha256)."""
    frames = frame_count(n)
    cmd = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-s",
        f"{WIDTH}x{HEIGHT}",
        "-r",
        str(FPS),
        "-i",
        "pipe:0",
        "-frames:v",
        str(frames),
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-crf",
        "23",
        "-threads",
        "1",
        "-an",
        "-map_metadata",
        "-1",
        "-movflags",
        "+faststart",
        str(out_path),
    ]
    hasher = hashlib.sha256()
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert proc.stdin is not None
    assert proc.stderr is not None
    try:
        for fi in range(frames):
            data = _make_frame(seed, fi)
            hasher.update(data)
            proc.stdin.write(data)
        proc.stdin.close()
        proc.stdin = None  # type: ignore[assignment]
        stderr = proc.stderr.read()
        returncode = proc.wait()
    except BrokenPipeError as exc:
        stderr = proc.stderr.read() if proc.stderr else b""
        proc.wait()
        err = stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"ffmpeg pipe broke during encode:\n{err}") from exc

    if returncode != 0:
        err = (stderr or b"").decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"ffmpeg encode failed ({returncode}):\n{err}")
    return frames, hasher.hexdigest()


def verify_decode(ffmpeg: str, mp4_path: Path) -> dict[str, object]:
    """Decode and return stable verify fields (framemd5 digest + frame count)."""
    proc = _run(
        [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(mp4_path),
            "-an",
            "-f",
            "framemd5",
            "-",
        ]
    )
    text = proc.stdout.decode("utf-8", errors="replace")
    lines = [ln for ln in text.splitlines() if ln.strip() and not ln.startswith("#")]
    body = "\n".join(lines).encode("utf-8")
    return {
        "decoded_frames": len(lines),
        "framemd5_sha256": hashlib.sha256(body).hexdigest(),
    }


def run(n: int, seed: int) -> dict[str, object]:
    ffmpeg = _require_ffmpeg()
    with tempfile.TemporaryDirectory(prefix="media-bench-") as tmp:
        mp4_path = Path(tmp) / "out.mp4"

        frames, input_sha256 = encode_h264_piped(
            ffmpeg, mp4_path, n=n, seed=seed
        )
        verify = verify_decode(ffmpeg, mp4_path)

        if verify["decoded_frames"] != frames:
            raise RuntimeError(
                f"decode frame count mismatch: expected {frames}, got {verify['decoded_frames']}"
            )

        return {
            "n": n,
            "seed": seed,
            "frames": frames,
            "width": WIDTH,
            "height": HEIGHT,
            "fps": FPS,
            "input_sha256": input_sha256,
            "output_bytes": mp4_path.stat().st_size,
            "decoded_frames": verify["decoded_frames"],
            "framemd5_sha256": verify["framemd5_sha256"],
            "codec": "libx264-ultrafast-crf23-t1",
        }

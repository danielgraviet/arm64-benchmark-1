"""TB-style: large messy logs → multi-pass cleanup pipeline → strict verify.

Heavy file I/O + CPU filtering so one trial is seconds of in-sandbox work.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

# Sized for ~1–3s local/sandbox duration on a single trial.
N_LINES = 1_500_000


def setup(workspace: Path, seed: int) -> None:
    raw = workspace / "var" / "app.log"
    raw.parent.mkdir(parents=True)
    # Deterministic pseudo-log stream (no RNG object — seed folds into lines).
    lines: list[str] = []
    for i in range(N_LINES):
        kind = (i + seed) % 5
        if kind == 0:
            lines.append(f"ERROR component=api id={i} code={i % 17}")
        elif kind == 1:
            lines.append(f"WARN component=cache id={i} hit=0")
        elif kind == 2:
            lines.append(f"DEBUG chatter noise={i} seed={seed}")
        elif kind == 3:
            lines.append(f"INFO component=worker id={i} ok=1")
        else:
            lines.append(f"TRACE skip me {i}")
    raw.write_text("\n".join(lines) + "\n", encoding="utf-8")
    (workspace / "README.md").write_text(
        "Clean ERROR+INFO+WARN into reports/; drop DEBUG/TRACE.\n",
        encoding="utf-8",
    )


def oracle(workspace: Path, seed: int) -> dict[str, Any]:
    """Multi-step pipeline like an agent shell session."""
    steps: list[str] = []
    raw_path = workspace / "var" / "app.log"
    text = raw_path.read_text(encoding="utf-8").splitlines()
    steps.append(f"read_lines={len(text)}")

    # Pass 1: drop TRACE/DEBUG
    pass1 = [
        ln
        for ln in text
        if not ln.startswith("DEBUG ") and not ln.startswith("TRACE ")
    ]
    (workspace / "var" / "pass1.log").write_text(
        "\n".join(pass1) + "\n", encoding="utf-8"
    )
    steps.append(f"pass1_kept={len(pass1)}")

    # Pass 2: keep ERROR/WARN/INFO only, normalize spacing
    keep_prefix = ("ERROR ", "WARN ", "INFO ")
    pass2 = [" ".join(ln.split()) for ln in pass1 if ln.startswith(keep_prefix)]
    reports = workspace / "reports"
    reports.mkdir(parents=True)
    out = reports / "clean.log"
    out.write_text("\n".join(pass2) + "\n", encoding="utf-8")
    steps.append(f"pass2_kept={len(pass2)}")

    # Pass 3: summary counts (agent would wc/grep)
    counts = {"ERROR": 0, "WARN": 0, "INFO": 0}
    for ln in pass2:
        key = ln.split(" ", 1)[0]
        if key in counts:
            counts[key] += 1
    summary = reports / "summary.txt"
    summary.write_text(
        f"seed={seed}\nERROR={counts['ERROR']}\nWARN={counts['WARN']}\nINFO={counts['INFO']}\n",
        encoding="utf-8",
    )
    steps.append("wrote reports/summary.txt")
    return {"steps": steps, "counts": counts, "seed": seed}


def verify(workspace: Path) -> dict[str, Any]:
    clean = workspace / "reports" / "clean.log"
    summary = workspace / "reports" / "summary.txt"
    if not clean.exists() or not summary.exists():
        return {"passed": False, "reason": "missing reports"}

    lines = [ln for ln in clean.read_text(encoding="utf-8").splitlines() if ln.strip()]
    bad = [
        ln
        for ln in lines
        if not (
            ln.startswith("ERROR ")
            or ln.startswith("WARN ")
            or ln.startswith("INFO ")
        )
    ]
    has_noise = any(x in ln for ln in lines for x in ("DEBUG", "TRACE"))

    # Recompute expected counts from raw (expensive enough to matter).
    raw = (workspace / "var" / "app.log").read_text(encoding="utf-8").splitlines()
    expected = {"ERROR": 0, "WARN": 0, "INFO": 0}
    for ln in raw:
        if ln.startswith("DEBUG ") or ln.startswith("TRACE "):
            continue
        for key in expected:
            if ln.startswith(key + " "):
                expected[key] += 1
                break

    summary_txt = summary.read_text(encoding="utf-8")
    counts_ok = all(f"{k}={expected[k]}" in summary_txt for k in expected)
    passed = (
        not bad
        and not has_noise
        and counts_ok
        and len(lines) == sum(expected.values())
        and len(lines) > 0
    )
    return {
        "passed": passed,
        "line_count": len(lines),
        "bad_lines": len(bad),
        "expected": expected,
    }

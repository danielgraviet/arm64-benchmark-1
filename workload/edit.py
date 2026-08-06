from pathlib import Path
from typing import Any

TARGET_FILE = "sqlite_utils/utils.py"
TARGET_LINE = (
    "def hash_record(record: Dict[str, Any], "
    "keys: Optional[Iterable[str]] = None) -> str:"
)
MARKER = "# benchmark: reviewed by scripted agent edit"


def run(repo_root: Path) -> dict[str, Any]:
    path = repo_root / TARGET_FILE
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)

    target_index = next(
        i for i, line in enumerate(lines) if line.rstrip("\n") == TARGET_LINE
    )

    already_applied = (
        target_index > 0 and lines[target_index - 1].strip() == MARKER
    )
    if not already_applied:
        lines.insert(target_index, MARKER + "\n")
        path.write_text("".join(lines), encoding="utf-8")

    return {
        "file": TARGET_FILE,
        "marker": MARKER,
        "already_present_before_edit": already_applied,
    }

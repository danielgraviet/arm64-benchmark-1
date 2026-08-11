from pathlib import Path
from typing import Any

# Candidate edit sites in the vendored package (deterministic order).
EDIT_TARGETS: list[tuple[str, str]] = [
    (
        "sqlite_utils/utils.py",
        "def hash_record(record: Dict[str, Any], "
        "keys: Optional[Iterable[str]] = None) -> str:",
    ),
    (
        "sqlite_utils/db.py",
        "class Database:",
    ),
    (
        "sqlite_utils/cli.py",
        "def cli():",
    ),
    (
        "sqlite_utils/plugins.py",
        "def get_plugins() -> List[Dict[str, Union[str, List[str]]]]:",
    ),
    (
        "sqlite_utils/__init__.py",
        "from .db import Database",
    ),
]

MARKER_PREFIX = "# benchmark: reviewed by scripted agent edit"


def run(repo_root: Path, n: int = 1) -> dict[str, Any]:
    """Apply marker edits to ``n`` sites (cycles targets if n is larger)."""
    if n < 1:
        raise ValueError("n must be >= 1")

    edits: list[dict[str, Any]] = []
    for i in range(n):
        rel_path, target_line = EDIT_TARGETS[i % len(EDIT_TARGETS)]
        marker = f"{MARKER_PREFIX} #{i}"
        path = repo_root / rel_path
        if not path.exists():
            rel_path, target_line = EDIT_TARGETS[0]
            path = repo_root / rel_path

        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        try:
            target_index = next(
                i_line
                for i_line, line in enumerate(lines)
                if line.rstrip("\n") == target_line
            )
        except StopIteration:
            target_index = 0

        already_applied = any(marker in line for line in lines)
        if not already_applied:
            lines.insert(target_index, marker + "\n")
            path.write_text("".join(lines), encoding="utf-8")

        edits.append(
            {
                "iteration": i,
                "file": rel_path,
                "marker": marker,
                "already_present_before_edit": already_applied,
            }
        )

    return {"iterations": n, "edits": edits}

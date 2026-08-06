import re
from pathlib import Path
from typing import Any

SOURCE_DIR = "sqlite_utils"
PATTERN = re.compile(r"\bdef \w+\(")


def run(repo_root: Path, n: int) -> dict[str, Any]:
    files = sorted((repo_root / SOURCE_DIR).glob("*.py"))
    per_file = []
    total_matches = 0
    for i in range(n):
        path = files[i % len(files)]
        text = path.read_text(encoding="utf-8")
        matches = len(PATTERN.findall(text))
        total_matches += matches
        per_file.append({"iteration": i, "file": path.name, "matches": matches})

    return {
        "iterations": n,
        "total_matches": total_matches,
        "per_file": per_file,
    }

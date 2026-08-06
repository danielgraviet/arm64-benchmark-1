import ast
from pathlib import Path
from typing import Any

SOURCE_DIR = "sqlite_utils"


def run(repo_root: Path, n: int) -> dict[str, Any]:
    files = sorted((repo_root / SOURCE_DIR).glob("*.py"))
    per_file = []
    total_functions = 0
    total_classes = 0
    for i in range(n):
        path = files[i % len(files)]
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=path.name)
        functions = sum(isinstance(node, ast.FunctionDef) for node in ast.walk(tree))
        classes = sum(isinstance(node, ast.ClassDef) for node in ast.walk(tree))
        total_functions += functions
        total_classes += classes
        per_file.append(
            {
                "iteration": i,
                "file": path.name,
                "functions": functions,
                "classes": classes,
            }
        )

    return {
        "iterations": n,
        "total_functions": total_functions,
        "total_classes": total_classes,
        "per_file": per_file,
    }

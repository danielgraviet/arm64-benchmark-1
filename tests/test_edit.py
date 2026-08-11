from pathlib import Path

from workload import edit


def test_edit_inserts_markers(vendored_repo: Path, tmp_path: Path) -> None:
    # Copy package tree so we never mutate the real vendored repo.
    dest_pkg = tmp_path / "sqlite_utils"
    dest_pkg.mkdir()
    for name in ("utils.py", "db.py", "cli.py", "plugins.py", "__init__.py"):
        src = vendored_repo / "sqlite_utils" / name
        if src.exists():
            (dest_pkg / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

    first = edit.run(tmp_path, n=2)
    second = edit.run(tmp_path, n=2)

    assert first["iterations"] == 2
    assert first["edits"][0]["already_present_before_edit"] is False
    assert second["edits"][0]["already_present_before_edit"] is True
    text = (dest_pkg / "utils.py").read_text(encoding="utf-8")
    assert edit.MARKER_PREFIX in text

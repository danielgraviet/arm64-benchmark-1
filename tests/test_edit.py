from pathlib import Path

from workload import edit


def test_edit_inserts_marker_once(vendored_repo: Path, tmp_path: Path) -> None:
    # Copy only the target file so we never mutate the real vendored repo.
    # Strip any leftover marker from previous benchmark runs first.
    dest = tmp_path / "sqlite_utils"
    dest.mkdir()
    raw = (vendored_repo / "sqlite_utils" / "utils.py").read_text(encoding="utf-8")
    cleaned = "\n".join(
        line for line in raw.splitlines() if line.strip() != edit.MARKER
    ) + "\n"
    (dest / "utils.py").write_text(cleaned, encoding="utf-8")

    first = edit.run(tmp_path)
    second = edit.run(tmp_path)
    text = (dest / "utils.py").read_text(encoding="utf-8")

    assert first["already_present_before_edit"] is False
    assert second["already_present_before_edit"] is True
    assert text.count(edit.MARKER) == 1
    assert edit.TARGET_LINE in text

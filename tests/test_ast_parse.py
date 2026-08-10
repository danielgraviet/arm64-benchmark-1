from pathlib import Path

from workload import ast_parse


def test_ast_parse_counts_are_stable(vendored_repo: Path) -> None:
    result = ast_parse.run(vendored_repo, n=3)

    assert result["iterations"] == 3
    assert result["total_functions"] == 87
    assert result["total_classes"] == 2
    assert len(result["per_file"]) == 3


def test_ast_parse_is_deterministic(vendored_repo: Path) -> None:
    assert ast_parse.run(vendored_repo, n=5) == ast_parse.run(vendored_repo, n=5)

from pathlib import Path

from workload import search


def test_search_match_counts_are_stable(vendored_repo: Path) -> None:
    result = search.run(vendored_repo, n=3)

    assert result["iterations"] == 3
    assert result["total_matches"] == 88
    assert len(result["per_file"]) == 3


def test_search_is_deterministic(vendored_repo: Path) -> None:
    assert search.run(vendored_repo, n=5) == search.run(vendored_repo, n=5)

from workload import sql


def test_sql_aggregates_are_stable_for_fixed_seed() -> None:
    result = sql.run(n=3, seed=42)

    assert result["row_count"] == 150
    assert result["by_category"] == [
        {"category": "commit", "n": 21, "total_score": 9748},
        {"category": "issue", "n": 28, "total_score": 14755},
        {"category": "pr", "n": 36, "total_score": 17623},
        {"category": "release", "n": 29, "total_score": 14793},
        {"category": "repo", "n": 36, "total_score": 17503},
    ]
    assert result["top_events"] == [
        {"id": 26, "category": "repo", "score": 997},
        {"id": 84, "category": "pr", "score": 996},
        {"id": 74, "category": "pr", "score": 995},
        {"id": 18, "category": "issue", "score": 981},
        {"id": 83, "category": "repo", "score": 977},
    ]


def test_sql_is_deterministic() -> None:
    assert sql.run(n=5, seed=42) == sql.run(n=5, seed=42)

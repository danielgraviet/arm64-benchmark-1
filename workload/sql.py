import random
from typing import Any

import sqlite_utils

ROWS_PER_UNIT = 50
CATEGORIES = ["repo", "issue", "pr", "commit", "release"]


def _generate_rows(n: int, seed: int) -> list[dict[str, Any]]:
    rng = random.Random(seed)
    rows = []
    for i in range(n * ROWS_PER_UNIT):
        rows.append(
            {
                "id": i,
                "category": CATEGORIES[rng.randrange(len(CATEGORIES))],
                "score": rng.randint(1, 1000),
                "label": f"item-{i}",
            }
        )
    return rows


def run(n: int, seed: int) -> dict[str, Any]:
    db = sqlite_utils.Database(memory=True)
    rows = _generate_rows(n, seed)
    db["events"].insert_all(rows, pk="id")

    by_category = list(
        db.query(
            "select category, count(*) as n, sum(score) as total_score "
            "from events group by category order by category"
        )
    )
    top_events = list(
        db.query(
            "select id, category, score from events "
            "order by score desc, id asc limit 5"
        )
    )

    db.close()

    return {
        "row_count": len(rows),
        "by_category": by_category,
        "top_events": top_events,
    }

"""Deterministic Parquet + DuckDB pipeline for memory-bandwidth-heavy work.

Scale knob ``n``:
  customers ≈ n * 2_000
  orders    ≈ n * 10_000
  items     ≈ n * 30_000

Chart C (optional bandwidth slide): use ``n=200`` so in-container
``duration_ms`` is multi-second (~2–3s locally) and a clear majority of wall
at c=1 after create tax. Keep smoke / Chart B-adjacent runs at ``n=5``–``10``.

Flow: generate → write Parquet → DuckDB scan/join/filter/aggregate →
checksum-friendly result dict.
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Any

import duckdb
import pyarrow as pa
import pyarrow.parquet as pq

CUSTOMERS_PER_N = 2_000
ORDERS_PER_N = 10_000
ITEMS_PER_N = 30_000
REGIONS = ("na", "eu", "apac", "latam")
CATEGORIES = ("compute", "storage", "network", "support")


def _generate_tables(n: int, seed: int) -> dict[str, pa.Table]:
    n_customers = max(n * CUSTOMERS_PER_N, 1)
    n_orders = max(n * ORDERS_PER_N, 1)
    n_items = max(n * ITEMS_PER_N, 1)

    # Pure arithmetic — no RNG object state surprises across platforms.
    customer_ids = list(range(n_customers))
    regions = [REGIONS[(seed + i) % len(REGIONS)] for i in customer_ids]
    tiers = [1 + ((seed * 17 + i * 3) % 5) for i in customer_ids]

    order_ids = list(range(n_orders))
    order_customers = [((seed + i * 7) % n_customers) for i in order_ids]
    order_cats = [CATEGORIES[(seed + i) % len(CATEGORIES)] for i in order_ids]
    order_amounts = [((seed * 31 + i * 13) % 10_000) + 1 for i in order_ids]

    item_ids = list(range(n_items))
    item_orders = [((seed + i * 11) % n_orders) for i in item_ids]
    item_qtys = [1 + ((seed + i * 5) % 8) for i in item_ids]
    item_prices = [((seed * 19 + i * 9) % 500) + 1 for i in item_ids]

    return {
        "customers": pa.table(
            {
                "customer_id": customer_ids,
                "region": regions,
                "tier": tiers,
            }
        ),
        "orders": pa.table(
            {
                "order_id": order_ids,
                "customer_id": order_customers,
                "category": order_cats,
                "amount": order_amounts,
            }
        ),
        "items": pa.table(
            {
                "item_id": item_ids,
                "order_id": item_orders,
                "qty": item_qtys,
                "unit_price": item_prices,
            }
        ),
    }


def _write_parquet(tables: dict[str, pa.Table], directory: Path) -> dict[str, str]:
    paths: dict[str, str] = {}
    for name, table in tables.items():
        path = directory / f"{name}.parquet"
        pq.write_table(table, path, compression="zstd")
        paths[name] = str(path)
    return paths


def _query(paths: dict[str, str]) -> dict[str, Any]:
    con = duckdb.connect(database=":memory:")
    try:
        con.execute(
            f"CREATE VIEW customers AS SELECT * FROM read_parquet('{paths['customers']}')"
        )
        con.execute(
            f"CREATE VIEW orders AS SELECT * FROM read_parquet('{paths['orders']}')"
        )
        con.execute(
            f"CREATE VIEW items AS SELECT * FROM read_parquet('{paths['items']}')"
        )

        by_region = con.execute(
            """
            SELECT c.region,
                   COUNT(DISTINCT o.order_id) AS order_count,
                   SUM(o.amount) AS total_amount,
                   AVG(o.amount) AS avg_amount
            FROM orders o
            JOIN customers c ON c.customer_id = o.customer_id
            WHERE o.amount >= 100
            GROUP BY c.region
            ORDER BY c.region
            """
        ).fetchall()

        by_category = con.execute(
            """
            SELECT o.category,
                   SUM(i.qty * i.unit_price) AS line_total,
                   COUNT(*) AS line_count
            FROM items i
            JOIN orders o ON o.order_id = i.order_id
            GROUP BY o.category
            ORDER BY o.category
            """
        ).fetchall()

        top_customers = con.execute(
            """
            SELECT c.customer_id,
                   c.region,
                   c.tier,
                   SUM(o.amount) AS spend
            FROM customers c
            JOIN orders o ON o.customer_id = c.customer_id
            GROUP BY c.customer_id, c.region, c.tier
            ORDER BY spend DESC, c.customer_id ASC
            LIMIT 10
            """
        ).fetchall()

        filtered = con.execute(
            """
            SELECT COUNT(*) AS n
            FROM items i
            JOIN orders o ON o.order_id = i.order_id
            JOIN customers c ON c.customer_id = o.customer_id
            WHERE c.tier >= 3 AND i.qty >= 2 AND o.category IN ('compute', 'storage')
            """
        ).fetchone()

        return {
            "by_region": [
                {
                    "region": r[0],
                    "order_count": int(r[1]),
                    "total_amount": int(r[2]),
                    "avg_amount": round(float(r[3]), 4),
                }
                for r in by_region
            ],
            "by_category": [
                {
                    "category": r[0],
                    "line_total": int(r[1]),
                    "line_count": int(r[2]),
                }
                for r in by_category
            ],
            "top_customers": [
                {
                    "customer_id": int(r[0]),
                    "region": r[1],
                    "tier": int(r[2]),
                    "spend": int(r[3]),
                }
                for r in top_customers
            ],
            "filtered_line_count": int(filtered[0]) if filtered else 0,
        }
    finally:
        con.close()


def run(n: int, seed: int) -> dict[str, Any]:
    tables = _generate_tables(n, seed)
    with tempfile.TemporaryDirectory(prefix="vera-analytics-") as tmp:
        paths = _write_parquet(tables, Path(tmp))
        query_result = _query(paths)

    return {
        "customers": tables["customers"].num_rows,
        "orders": tables["orders"].num_rows,
        "items": tables["items"].num_rows,
        **query_result,
    }

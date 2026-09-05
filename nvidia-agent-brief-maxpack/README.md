# Agent max-pack ladder — charts & data inventory

Extension to [`../nvidia-agent-brief-704-zen5/`](../nvidia-agent-brief-704-zen5/): **512 MiB** sandboxes, concurrency **880–2,784**.

**Brief:** [`nvidia-agent-brief-maxpack.md`](nvidia-agent-brief-maxpack.md)  
**Data inventory:** [`maxpack-data-inventory.md`](maxpack-data-inventory.md)  
**Pinned JSONL:** [`sources.md`](sources.md)

```bash
# Vera + 9J45 + 9575
uv run python scripts/nvidia_brief_maxpack_charts.py

# Hide 9575 on the PNGs (jsonl still written)
uv run python scripts/nvidia_brief_maxpack_charts.py --no-9575
```

Charts: `throughput_vs_concurrency.png`, `duration_vs_concurrency.png`.

Ground truth JSONL (merged per chip): `vera.jsonl`, `zen5-9j45.jsonl`, `zen5-9575.jsonl`.

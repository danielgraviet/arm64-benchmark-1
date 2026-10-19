"""Canonical JSONL sources for one-socket Vera / 9575F / 9755 graphs.

Edit paths here when a newer clean run should become the chart series.
"""

from __future__ import annotations

from pathlib import Path

FOCUS = Path(__file__).resolve().parent.parent

# Dense agent hold-then-exec (n=45, 44→2000).
DENSE = {
    "vera": FOCUS
    / "vera-jsonl"
    / "vera_graph_source_dense2k_20260906_183636.jsonl",
    "zen5_9575f": FOCUS
    / "zen5-9575f-jsonl"
    / "concurrency_20260908_122958_n45.jsonl",
    "zen5_9755": FOCUS
    / "zen5-9755-jsonl"
    / "concurrency_20260923_180424_n45_tuned_cleanest.jsonl",
}

# Create-ready aggregate stubs (one row per repeat).
READY_1K = {
    "vera": FOCUS / "vera-jsonl" / "vera_graph_ready_1k.jsonl",
    "zen5_9575f": FOCUS / "zen5-9575f-jsonl" / "zen5_graph_ready_1k.jsonl",
    "zen5_9755": FOCUS / "zen5-9755-jsonl" / "zen5_9755_graph_ready_1k.jsonl",
}

READY_2K = {
    "vera": FOCUS / "vera-jsonl" / "vera_graph_ready_2k.jsonl",
    "zen5_9575f": FOCUS / "zen5-9575f-jsonl" / "zen5_graph_ready_2k.jsonl",
}

# Create-ready repeats whose summary row lives in the file (or a .meta.json sidecar).
# The READY_* stubs above are the older chart series. Headline prose uses these runs.
READY_1K_RUNS = {
    "vera": [
        FOCUS / "vera-jsonl" / "vera_create_ready_1000_20260908_121324.jsonl",
        FOCUS / "vera-jsonl" / "vera_create_ready_1000_rep2_20260908_121545.jsonl",
        FOCUS / "vera-jsonl" / "vera_create_ready_1000_clean_20260908_122335.jsonl",
        FOCUS / "vera-jsonl" / "vera_create_ready_1000_clean2_20260908_123044.jsonl",
    ],
    "zen5_9575f_sep": [
        FOCUS.parent
        / "results"
        / "zen5-jsonl"
        / "redswitches_create_ready_1000_20260908_202913.jsonl",
        FOCUS.parent
        / "results"
        / "zen5-jsonl"
        / "redswitches_create_ready_1000_20260908_210003.jsonl",
        FOCUS.parent
        / "results"
        / "zen5-jsonl"
        / "redswitches_create_ready_1000_20260908_225335.jsonl",
    ],
    "zen5_9575f_oct": [
        FOCUS / "zen5-9575f-jsonl" / "epyc9575_create_ready_1000_20261002_232050.jsonl",
        FOCUS / "zen5-9575f-jsonl" / "epyc9575_create_ready_1000_20261002_232214.jsonl",
    ],
    "zen5_9755": [
        FOCUS / "zen5-9755-jsonl" / "epyc9755_create_ready_1000_20260923_202107.jsonl",
        FOCUS / "zen5-9755-jsonl" / "epyc9755_create_ready_1000_20260923_202758.jsonl",
        FOCUS / "zen5-9755-jsonl" / "epyc9755_create_ready_1000_20260923_203040.jsonl",
        FOCUS / "zen5-9755-jsonl" / "epyc9755_create_ready_1000_20260923_203449.jsonl",
    ],
}

READY_2K_RUNS = {
    "vera": [
        FOCUS / "vera-jsonl" / "vera_create_ready_2000_rep1_20260908_133315.jsonl",
        FOCUS / "vera-jsonl" / "vera_create_ready_2000_rep2_20260908_133731.jsonl",
        FOCUS / "vera-jsonl" / "vera_create_ready_2000_clean_20260908_140442.jsonl",
    ],
    "zen5_9575f": [
        FOCUS / "zen5-9575f-jsonl" / "epyc9575_create_ready_2000_20261002_232612.jsonl",
        FOCUS / "zen5-9575f-jsonl" / "epyc9575_create_ready_2000_20261002_233120.jsonl",
        FOCUS / "zen5-9575f-jsonl" / "epyc9575_create_ready_2000_20261002_233826.jsonl",
        FOCUS / "zen5-9575f-jsonl" / "epyc9575_create_ready_2000_20261002_234110.jsonl",
    ],
}

# Display labels (match published Vera share charts).
LABELS = {
    "vera": "Vera single socket",
    "zen5_9575f": "Zen 5 9575F",
    "zen5_9755": "Zen 5 9755",
}

# Vera = NVIDIA green. AMD SKUs stay dimmer so Vera reads first.
COLORS = {
    "vera": "#76B900",
    "zen5_9575f": "#6F7177",
    "zen5_9755": "#C47A3A",
}

# Point-label offsets for line charts (above / below markers).
ANNOTATE_OFFSET = {
    "vera": 8,
    "zen5_9755": -12,
    "zen5_9575f": -18,
}

GRAPHS = FOCUS / "graphs"

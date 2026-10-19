# Plotting (reuse)

From repo root:

```bash
uv run python daniel-focus-here/plotting/plot_three_way.py
```

Or from this folder:

```bash
cd daniel-focus-here && uv run python -m plotting.plot_three_way
```

Canonical JSONL paths live in `sources.py`. Swap a path there when a newer clean run should become the chart series, then re-run the plotter.

Outputs land in `../graphs/`:

- `throughput_3way_44_2000.png` (3 lines)
- `p50_duration_3way_44_2000.png` (3 lines)
- `create_1000_3way.png` (3 bars, from the `READY_1K` chart stubs)
- `create_2000_vera_9575f.png` (Vera vs 9575F, median bar, one dot per repeat)
- `peak_throughput_3way.png` (3 bars)
- `throughput_at_2000_3way.png` (3 bars)

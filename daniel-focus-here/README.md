# Daniel focus here

One-socket Vera vs Zen5 deliverables. Layout:

```
daniel-focus-here/
  README.md
  docs/                 # briefs (final, ivan, metrics, marketing)
  graphs/               # PNGs linked from docs
  plotting/             # reusable matplotlib (sources + plot_three_way)
  vera-jsonl/           # Vera socket0 runs used for these docs
  oci-vera-jsonl/       # OCI Vera box runs, not the onsite socket
  zen5-9575f-jsonl/     # Zen5 EPYC 9575F (old RedSwitches)
  zen5-9755-jsonl/      # Zen5 EPYC 9755 (veraTest)
```

Harness and full history stay in repo `data/`. Do not scatter briefs at repo root.

## The only three-way

Same agent dense recipe (`n=45`, `0.025` cpu, hold-then-exec, through 2000). One socket each:

1. **Vera socket 0** → `vera-jsonl/`
2. **Zen5 9575F** → `zen5-9575f-jsonl/`
3. **Zen5 9755** → `zen5-9755-jsonl/` (`veraTest`)

No 9J45. No Phoenix. No dual-socket NVIDIA vendor pack here.

## Graphs

Canonical JSONL paths live in [plotting/sources.py](plotting/sources.py). Rebuild:

```bash
uv run python daniel-focus-here/plotting/plot_three_way.py
```

See [plotting/README.md](plotting/README.md).

## Docs

- [docs/updated-ivan-doc-9755.md](docs/updated-ivan-doc-9755.md) — three-way (Vera / 9575F / 9755)
- [docs/updated-ivan-doc-9755.pdf](docs/updated-ivan-doc-9755.pdf) — share PDF
- [docs/updated-ivan-doc.md](docs/updated-ivan-doc.md) — earlier Vera vs 9575F only
- [docs/final.md](docs/final.md)
- [docs/headline_metrics.md](docs/headline_metrics.md)
- [docs/agentic-sandbox-cpu-report.md](docs/agentic-sandbox-cpu-report.md) — technical report (packed plateau vs cold admit)
- [docs/rlp-vera-coincidence.md](docs/rlp-vera-coincidence.md) — RLP code review: coincidental Vera favor on create path

Rebuild the PDF (same fpdf2 path as the original Ivan share):

```bash
python3 daniel-focus-here/ivan_doc_to_pdf.py
```

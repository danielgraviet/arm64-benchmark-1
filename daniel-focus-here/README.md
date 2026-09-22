# Daniel focus here

One-socket Vera vs Zen5 deliverables. Layout:

```
daniel-focus-here/
  README.md
  docs/                 # briefs (final, ivan, metrics, marketing)
  graphs/               # PNGs linked from docs
  vera-jsonl/           # Vera socket0 runs used for these docs
  zen5-9575f-jsonl/     # Zen5 EPYC 9575F (old RedSwitches) — have
  zen5-9755-jsonl/      # Zen5 EPYC 9755 (veraTest) — collect next
```

Harness and full history stay in repo `data/`. Do not scatter briefs at repo root.

## The only three-way

Same agent dense recipe (`n=45`, `0.025` cpu, hold-then-exec, through 2000). One socket each:

1. **Vera socket 0** → `vera-jsonl/`
2. **Zen5 9575F** → `zen5-9575f-jsonl/`
3. **Zen5 9755** → `zen5-9755-jsonl/` (`veraTest`)

No 9J45. No Phoenix. No dual-socket NVIDIA vendor pack here.

## Docs to refresh after 9755

- [docs/final.md](docs/final.md)
- [docs/updated-ivan-doc.md](docs/updated-ivan-doc.md)
- [docs/headline_metrics.md](docs/headline_metrics.md)

## When RLP is live on `veraTest`

Hand Codex [../tickets/codex-zen5-dense2k-go.md](../tickets/codex-zen5-dense2k-go.md). After push, copy the new JSONL into `zen5-9755-jsonl/`, refresh graphs, rewrite the docs above.

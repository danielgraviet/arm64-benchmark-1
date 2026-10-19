# Eng note — epyc9755 (2026-09-23)

Source: eng `updated-instructions.md` for host `57.128.100.53` (`veraTest`).

## Applied in harness

- `--target epyc9755` (region id == target). Toolbox + API default to localhost.
- Cell key: `RLP_API_KEY` with `dtn_` prefix. Prefer over stale `RS_KEY` (`rlp_`).
- Wrapper `scripts/host/run_dense2k.sh` re-pins localhost URLs after sourcing `.env`,
  sets `RLP_HTTP_MAX_CONNECTIONS=8192`, tees log to `/mnt/data/bench-logs/`.
- Create pickup is hard-capped at **60s** in-cell (`CREATE_MAX_QUEUE_SECS_CAP`);
  `RLP_CREATE_MAX_QUEUE_SECS=600` does nothing.

## Operator run

```bash
tmux new-session -d -s zen5-dense2k bash scripts/host/run_dense2k.sh
```

Full recipe stays 44→2000 / n=45 / E=8 / cpu 0.025/max1 / mem 0.0625 / burst 0.5.
Do not `killall -9 firecracker`. Drain via cleanup script / API deletes.

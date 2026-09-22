# Codex: Zen5 9755 agent dense2k (go when RLP is live)

**You are on the DUT.** Cwd: `/home/ubuntu/arm64-benchmark-1`. Do not drive load from a Mac tunnel. No `/tmp` wrappers. No `scp`.

Three-way compare this run feeds: **Vera socket0**, **9575F** (already in git), **this 9755**. No 9J45.

## Gate (stop if any fail)

```bash
docker ps   # must show postgresql and nats
curl -fsS http://127.0.0.1:8088/health
scripts/host/status.sh   # cell empty, no leftover experiment tmux
```

If `.env` still has an empty `RLP_API_KEY`, ask the human for it and paste it. Never commit `.env`.

## Run (agent only)

```bash
git pull
tmux new-session -d -s zen5-dense2k bash scripts/host/run_dense2k.sh
```

Stay in your own `tmux` session named `codex`. Do not start create-ready. Do not change `--n` (wrapper is **n=45**, not 50).

**Primary output:** `daniel-focus-here/zen5-9755-jsonl/concurrency_<utc>_n45.jsonl`  
(Also mirrored to `data/agent/rlp-redswitches-9755-c0p025-max1/` for `eda.py`.)

Log: `/tmp/zen5-dense2k-n45.log`.

## When the ladder tmux is gone

1. `scripts/host/status.sh` — confirm `END_EXIT=0` in the log, FC≈0.
2. `git add` the new JSONL under **both**:
   - `daniel-focus-here/zen5-9755-jsonl/`
   - `data/agent/rlp-redswitches-9755-c0p025-max1/`
3. One commit for this run, `git push`.
4. Tell the human the focus path so the Mac can `git pull` and graph:

```bash
uv run python eda.py --benchmark agent \
  --include rlp-vera-c0p025-max1 rlp-redswitches-c0p025-max1 rlp-redswitches-9755-c0p025-max1
```

## Do not

- Reboot for MOTD
- Set `UV_NO_SYNC=1`
- Invent a different recipe or levels
- Write into `zen5-9575f-jsonl/` or `data/agent/rlp-redswitches-c0p025-max1/`
- Leave results only on the DUT

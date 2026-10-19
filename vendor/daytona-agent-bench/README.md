# Agent sandbox ladder (dual-socket EPYC 9755)

On-node RLP client for one workload: the coding-agent task Daytona uses inside sandboxes (`repo-agent-v3`). Run it on the dual-socket 9755, next to the cell. Send back one JSONL.

**Do not change `--n`.** This pack is `--n 50`. That matches the dual-socket Vera / 9J45 maxpack already collected. `--n 45` was a different single-socket dense recipe. Do not "fix" it.

Start at [SETUP.md](SETUP.md). The packed run is:

```bash
tmux new-session -d -s agent-ladder bash scripts/run_ladder.sh
```

When that session is gone and the log says `END_EXIT=0`, send `results/agent_hold_then_exec.jsonl`.

Smoke:

```bash
uv run pytest
uv run main.py --benchmark agent --runner rlp --target local \
  --levels 1 --n 1 --seed 42 -E 1
```

`pytest` needs no cell. `--levels 1` creates one sandbox on `http://127.0.0.1:8088` and deletes it.

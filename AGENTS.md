# On-box operator (RedSwitches / Codex)

This repo is the harness. On a RedSwitches DUT, Codex is the operator. GitHub is the sync plane. The Mac only `git pull`s to graph.

Cwd is the clone (usually `/home/ubuntu/arm64-benchmark-1`). The RLP API and toolbox are on localhost. Never drive a ladder from a laptop SSH tunnel. That measures the tunnel.

## How to run

Use the git-tracked wrappers. Do not invent `/tmp` scripts.

```bash
scripts/host/status.sh
tmux new-session -d -s zen5-dense2k bash scripts/host/run_dense2k.sh
tmux new-session -d -s zen5-create2k bash scripts/host/run_create_ready.sh 2000
```

Long jobs get their own tmux session. Keep Codex in a separate `tmux` session named `codex` so closing the agent does not kill a ladder.

Cleanup is inside the wrappers (`scripts/phoenix_rlp_cleanup_sandboxes.py --target redswitches`). GET `/vms` is paginated. `Daytona.list()` is page 1 only.

## Python / uv

This host uses `uv python install 3.13` then `uv sync`, then eng editable `rlp-sdk`:

```bash
bash scripts/host/install_eng_rlp_sdk.sh
```

Prefix harness commands with `UV_NO_SYNC=1` (dense2k wrapper already does). Do not bare-`uv sync` without reinstalling the overlay. That reverts to PyPI `0.3.2` and drops `--rlp-cpu-max`.

Do not `reboot` because MOTD said restart required. Do not rotate the root password.

## After a run

1. `scripts/host/status.sh` (tmux gone, FC=0, `END_EXIT=0` in the log).
2. `git add` the new JSONL under `data/` or `results/`. Never add `.env`, `.venv`, or `.DS_Store`.
3. Commit (one run per commit) and `git push`.
4. Tell the human the path so the Mac can `git pull` and graph.

## Sandbox

Run on the host, not inside a Codex container. The harness must see `http://127.0.0.1:8088` and raise `RLIMIT_NOFILE` in the same process.

See `tickets/redswitches-codex-host.md`.

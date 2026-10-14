# On-box operator (RedSwitches / Vera HQ / Codex)

This repo is the harness. On a RedSwitches DUT or Vera HQ, Codex is the operator. GitHub is the sync plane. The Mac only `git pull`s to graph (and leave notes under `codex-direction-log/`).

Vera HQ is Axis-only (`ssh.axisapps.io`). Agents on the Mac cannot usefully Remote-SSH it. See `tickets/vera-codex-host.md`. RedSwitches: `tickets/redswitches-codex-host.md`.

Cwd is the clone (usually `/home/ubuntu/arm64-benchmark-1`). The RLP API and toolbox are on localhost. Never drive a ladder from a laptop SSH tunnel. That measures the tunnel.

## Before any benchmark — read `docs/benchmark-methodology.md`

Short version (every point broke a published number at least once):

- **One operator per box.** Check `tmux ls`, `w`, `ls /etc/systemd/system/rlp-*.service.d/` first.
- **Gate every rep** with `scripts/host/bench-preflight.sh <outdir>` (floor script, background CPU, warm netns pool,
  hugepages, ARP limits, leftovers, balloon). It also records kernel/page size/cmdline/power cap/pins/binary SHAs.
- **`post_s` is not control-plane time** when the client is one Python process; for bursts ≥ 500 use
  `mpfleet.py --procs 16` and report `procs`.
- **Record placement.** On dual-socket hosts, pinning runner + sandboxes to one NUMA node changes 1k startup 2.3×.
- **Same build, daemon, SDK, guest shape and client settings on every platform compared.**

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

See `tickets/redswitches-codex-host.md` (x86 cells) and `tickets/vera-codex-host.md` (Vera HQ / Axis).

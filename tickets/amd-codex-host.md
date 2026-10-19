# AMD EPYC 9996 on-box Codex operator

**For:** anyone running experiments on the AMD vendor EPYC 9996 cell  
**Not for:** RedSwitches, Vera Axis, OCI Phoenix E6, or driving load from a Mac SSH tunnel

Codex runs **on the box**. GitHub is the sync plane. The Mac only `git pull`s to graph and to leave directions under `codex-direction-log/`. Focused pack: [`amd/`](../amd/) (`./o start` boots the empty cell).

## This box

| | |
|---|---|
| SSH | `daytonaio@165.204.53.121 -p 30208` (Mac: `./amd/ssh` or `Host amd-daytona`) |
| Chip | AMD EPYC 9996, 2 sockets × 256 cores (1024 logical CPUs, 4 NUMA nodes) |
| Clone | `/home/daytonaio/arm64-benchmark-1` |
| Target | `--target epyc9996` (localhost `:8088` / toolbox `:9000`) |
| Python | 3.13 via `uv` + eng editable `rlp-sdk` (`UV_NO_SYNC=1`) |
| Pin | NUMA node 0 before timed runs: `cd amd && ./o pin` |
| Results | `daniel-focus-here/zen5-9996-jsonl/` |

Unlike RedSwitches, **we** bring up RLP on this empty Ubuntu (`cd amd && ./o start`). Need passwordless sudo (`sudo -n true`) and `/dev/kvm`.

## Once per box

1. Mac break-glass (optional after pubkey):

```
Host amd-daytona
  HostName 165.204.53.121
  Port 30208
  User daytonaio
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Password lives only in gitignored `amd/.env.amd`. Run `./amd/install_pubkey.sh` once.

2. On the box:

```bash
sudo -n true && echo sudo=passwordless
test -e /dev/kvm && echo kvm=yes
git clone https://github.com/danielgraviet/arm64-benchmark-1.git ~/arm64-benchmark-1
cd ~/arm64-benchmark-1/amd
export GH_TOKEN='…'   # read rlp-bench-pin, write this repo
./o start
./o hw && ./o pin && ./o test
```

3. `gh auth login` with a fine-grained PAT (this repo, contents:write). Prefer `gh auth setup-git`.

4. Codex login (pick one):

```bash
codex login --device-auth
# or copy ~/.codex/auth.json from the Mac (treat like a password)
```

`./o start` / [`scripts/host/bootstrap.sh`](../scripts/host/bootstrap.sh) can install Codex. Keep a durable session:

```bash
tmux new-session -s codex
# inside: cd ~/arm64-benchmark-1 && export PATH="$HOME/.local/bin:$PATH" && export UV_NO_SYNC=1
```

Do not reboot because MOTD said restart required.

## Day to day

**Directions Mac → box (Codex):**

1. Edit or add a note under `codex-direction-log/` on the Mac.
2. Commit and `git push`.
3. On the box, in `tmux attach -t codex`: `git pull`, then have Codex follow the note.

**Results box → Mac:**

1. Recipes in their **own** tmux (do not kill `codex`):

```bash
cd ~/arm64-benchmark-1/amd
./o clean && ./o 1k
# attach: tmux attach -t zen5-1k
```

2. When the experiment tmux is gone: `./o status`, confirm `END_EXIT=0`, `git add` JSONL under `daniel-focus-here/zen5-9996-jsonl/`, commit, `git push`. Never commit `.env`, `amd/.env.amd`, or `~/.codex/auth.json`.

3. On the Mac: `git pull`, then graph.

## What not to do

- Drive ladders from a laptop tunnel
- Put wrappers in `/tmp`
- Cross-wire `nvidia/` or `phoenix-e6/` recipes onto this chip
- Commit secrets
- Quote results without socket pin when comparing to Vera / 9575F / 9755

# Vera HQ on-box Codex operator

**For:** anyone running experiments on the NVIDIA Vera HQ cell via Axis  
**Not for:** RedSwitches, OCI Vera bootstrap, or driving load from a Mac SSH tunnel

Cursor / agents on the Mac fail against Axis (`ssh.axisapps.io`): Axis needs an interactive PTY and rejects `BatchMode`. Do not fight that. Codex runs **on the box**. GitHub is the sync plane. The Mac only `git pull`s to graph and to leave directions under `codex-direction-log/`.

Cell facts (API URLs, placement fields, eng SDK rules) stay in [tickets/vera-server-setup.md](vera-server-setup.md). This ticket is the operator loop.

## This box

| | |
|---|---|
| Access | Axis only: `ssh -o UpdateHostKeys=no -l <axis-session-user> ssh.axisapps.io` |
| Shell user | `daytona` (shared). Prompt often shows `daytona@localhost`. |
| Arch | aarch64 / Vera |
| Clone | `/home/daytona/arm64-benchmark-1` |
| Eng SDK | `/home/daytona/rlp` at commit `660e6e3b` via `RLP_PIN=660e6e3b bash scripts/host/install_eng_rlp_sdk.sh` |
| Python | 3.13 via `uv` + `UV_NO_SYNC=1` after the eng overlay |
| API | `http://127.0.0.1:8088` (co-located only) |

The Axis `User` **rotates**. Update Mac `~/.ssh/config` when the portal issues a new id. Do not reboot because apt/MOTD said a newer kernel is pending.

## Once per box (what worked 2026-10-13)

Human interactive Axis SSH first. Soft installs under `~` where possible. `sudo apt-get install -y gh` is fine; ignore the kernel-upgrade nag.

```bash
# 1) uv
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# 2) harness clone (public HTTPS worked without auth)
cd ~
git clone https://github.com/danielgraviet/arm64-benchmark-1.git
cd ~/arm64-benchmark-1

# 3) Python + venv
uv python install 3.13
uv sync

# 4) gh (Ubuntu package) + auth, then wire git
sudo apt-get update
sudo apt-get install -y gh
# do not reboot for the pending-kernel message
gh auth login -h github.com -p https -w
gh auth setup-git

# 5) eng rlp-sdk
# danielgraviet/rlp may 404 for gh; install script falls back to daytona/rlp.
# That tree has no bench-pin branch. Pin the eng commit explicitly:
rm -rf ~/rlp
RLP_PIN=660e6e3b bash scripts/host/install_eng_rlp_sdk.sh
UV_NO_SYNC=1 uv run python -c \
  "from rlp import DaytonaConfig, Resources; assert 'region_routing' in DaytonaConfig.__dataclass_fields__; assert 'cpu_max' in Resources.__dataclass_fields__; print('eng rlp-sdk OK')"

# 6) Codex
curl -fsSL https://chatgpt.com/codex/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
codex login --device-auth

# 7) .env (never commit)
cp -n .env.example .env
chmod 600 .env
# Fill VERA_RLP_API_KEY / RLP_API_KEY from the cell owner or /opt/bench/.env.
# Keep URLs on localhost:
#   VERA_RLP_API_URL=http://127.0.0.1:8088
#   VERA_RLP_TOOLBOX_URL=http://127.0.0.1:9000/toolbox
#   VERA_RLP_TARGET=vera

curl -fsS http://127.0.0.1:8088/health

# 8) durable Codex session (separate from experiment tmux)
tmux new-session -s codex
# inside: cd ~/arm64-benchmark-1 && export PATH="$HOME/.local/bin:$PATH" && export UV_NO_SYNC=1
```

Shared-account soft rules: do not write a PAT into `~/.git-credentials` by hand (use `gh auth setup-git`). Do not mutate `/opt/bench` casually. `~/rlp-build` is a cell build tree, not the eng Python SDK.

## Day to day

**Directions Mac → Vera (Codex):**

1. Edit or add a note under `codex-direction-log/` on the Mac.
2. Commit and `git push`.
3. On Vera, in `tmux attach -t codex`: `git pull`, then have Codex follow the note.

**Results Vera → Mac:**

1. On Vera: run recipes in their **own** tmux sessions (do not kill `codex`):

```bash
tmux new-session -d -s vera-dense2k bash scripts/host/run_dense2k_vera.sh
# or create-ready / other git-tracked wrappers
```

2. When the experiment tmux is gone: confirm success, `git add` JSONL under `data/` or agreed paths, commit, `git push`. Never commit `.env` or `~/.codex/auth.json`.

3. On the Mac: `git pull`, then graph / analyze.

Break-glass only: interactive Axis SSH. Never drive concurrency ladders through a laptop tunnel. That measures the tunnel.

## Mac SSH config shape

```sshconfig
Host vera-axis
  HostName ssh.axisapps.io
  Port 22
  User <current-axis-session-user-id>
```

`UpdateHostKeys=no` on the CLI avoids noisy host-key prove failures some clients hit on Axis.

## What not to do

- Cursor Remote SSH or agent `BatchMode` SSH against Axis
- Bare `uv sync` / `uv run` without reinstalling eng SDK and keeping `UV_NO_SYNC=1`
- `RLP_PIN=bench-pin` against the `daytona/rlp` fallback clone (use `660e6e3b`)
- Reboot for apt kernel diagnostics
- Leave result files only on the DUT

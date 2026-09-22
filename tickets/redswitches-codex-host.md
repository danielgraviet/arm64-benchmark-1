# RedSwitches on-box Codex operator

**For:** anyone running experiments on a new RedSwitches DUT
**Not for:** Vera Axis, Phoenix, or driving load from a Mac SSH tunnel

The last box was painful because Cursor on the Mac was the operator. Password SSH, `expect`, `/tmp` wrappers, `UV_NO_SYNC=1`, and `scp` of JSONL. This host is self-contained. Codex runs on the box. GitHub holds code and results. The Mac graphs.

## This box

| | |
|---|---|
| SSH | `ssh rs-new` or `ubuntu@57.128.100.53` |
| Chip | AMD EPYC 9755 (higher-frequency Zen5 cell for Vera compare) |
| Clone | `/home/ubuntu/arm64-benchmark-1` |
| Python | 3.13 via `uv` + eng editable `rlp-sdk` (`UV_NO_SYNC=1`) |
| Login ulimit | 1048576 |
| Eng SDK | `/home/ubuntu/rlp` pinned to `660e6e3b` via `scripts/host/install_eng_rlp_sdk.sh` |

RLP runner is eng's job. Wait until `docker ps` shows postgresql and nats and `curl -fsS http://127.0.0.1:8088/health` returns ok. Then paste `RLP_API_KEY` into `.env`.

Dense2k needs eng `Resources.cpu_max` / `memory_max`. PyPI `0.3.2` is not enough. After any bare `uv sync`, re-run `bash scripts/host/install_eng_rlp_sdk.sh` and keep `UV_NO_SYNC=1` (the dense2k wrapper already sets it).

## Once per box

1. Pubkey SSH on the Mac:

```
Host rs-new
  HostName 57.128.100.53
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

2. Clone, then bootstrap as root:

```bash
git clone https://github.com/danielgraviet/arm64-benchmark-1.git /home/ubuntu/arm64-benchmark-1
cd /home/ubuntu/arm64-benchmark-1
bash scripts/host/bootstrap.sh
```

Bootstrap installs uv, CPython 3.13, `uv sync`, PAM/systemd `nofile=1048576`, `gh`, and Codex. It copies `.env.example` to `.env` if missing.

3. Fill `RLP_API_KEY` in `.env` by hand. Never commit it.

4. `gh auth login` with a fine-grained PAT (this repo, contents:write).

5. Codex headless login (pick one):

```bash
codex login --device-auth
printenv OPENAI_API_KEY | codex login --with-api-key
```

Or login on the Mac and copy `~/.codex/auth.json` to the box. Treat that file like a password.

6. Smoke (skip `:8088/health` until eng has RLP up):

```bash
bash scripts/host/install_eng_rlp_sdk.sh
UV_NO_SYNC=1 uv run pytest
scripts/host/status.sh
```

`UV_NO_SYNC=1` keeps the eng editable `rlp-sdk` (burst caps). After any bare `uv sync`, re-run `install_eng_rlp_sdk.sh`.

Do not reboot because MOTD said restart required.

## Day to day

On the box, in `tmux attach -t codex`:

1. `git pull`
2. `scripts/host/status.sh` (cell empty, no leftover experiment session)
3. Start a recipe in its own tmux:

```bash
tmux new-session -d -s zen5-dense2k bash scripts/host/run_dense2k.sh
tmux new-session -d -s zen5-create2k bash scripts/host/run_create_ready.sh 2000
```

4. When that tmux is gone: confirm `END_EXIT=0`, commit the JSONL, `git push`.

On the Mac:

```bash
git pull
uv run python eda.py --benchmark agent
```

No `expect`. No `scp`. No Cursor SSH hop. `ssh rs-new` is break-glass only.

## What not to do

- Drive c>=88 ladders from a laptop tunnel
- Put wrappers in `/tmp`
- Commit `.env` or Codex `auth.json`
- Quote a 1024-FD plateau as silicon (`harness/rlimit_nofile.py` refuses to start)
- Leave result files only on the DUT

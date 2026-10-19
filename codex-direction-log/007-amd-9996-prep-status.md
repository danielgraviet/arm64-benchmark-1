# Status: AMD 9996 prep (Mac → box) before create-ready 1k

Mac rsynced the pack and ran `scripts/host/bootstrap.sh` on the box. Host unlock is done.

## Done on box

- `sudo=passwordless`, `/dev/kvm` present, chip EPYC 9996
- Mac pubkey SSH (`./amd/ssh` / `./amd/install_pubkey.sh`)
- Tree at `~/arm64-benchmark-1` including `amd/`, ticket, direction `006`
- `uv`, `gh`, Codex CLI installed via `scripts/host/bootstrap.sh`
- `.env` stub from `.env.example` (no `RLP_API_KEY` yet — minted by `./o start`)

## Still needed (human / Codex)

1. **`GH_TOKEN`** with Contents:Read on `danielgraviet/rlp-bench-pin` (and write on this repo for result push).
2. `cd ~/arm64-benchmark-1/amd && export GH_TOKEN=… && ./o start`
3. `./o hw && ./o pin && ./o test`
4. `./o clean && ./o 1k` then commit JSONL under `daniel-focus-here/zen5-9996-jsonl/`
5. `gh auth login` + `codex login --device-auth` + durable `tmux new-session -s codex`

Follow [`006-amd-9996-empty-bringup.md`](006-amd-9996-empty-bringup.md) for the ordered steps.

## Mac note

Commit + `git push` the new `amd/` pack so the box can `git pull` instead of relying on rsync. Never commit `amd/.env.amd`.

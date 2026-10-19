# Direction: AMD EPYC 9996 empty cell → create-ready 1000

You are Codex on the AMD vendor box (`daytonaio@…`, clone `~/arm64-benchmark-1`). Mac SSH is break-glass only. Work on-box. Commit JSONL + short notes; `git push` so the Mac can pull.

Playbook: [`tickets/amd-codex-host.md`](../tickets/amd-codex-host.md). Pack: [`amd/`](../amd/).

## Goal

1. Bring up RLP on empty Ubuntu (`--target epyc9996`).
2. Pin NUMA node 0.
3. Smoke + parity.
4. Create-ready **1000** with 0 failures. JSONL under `daniel-focus-here/zen5-9996-jsonl/`.

## Do this in order

Stay in `tmux` session `codex`. Experiment runs go in their **own** tmux.

### 0) Pull and cwd

```bash
export PATH="$HOME/.local/bin:$PATH"
export UV_NO_SYNC=1
cd ~/arm64-benchmark-1
git pull
```

If the clone does not exist yet:

```bash
cd ~
git clone https://github.com/danielgraviet/arm64-benchmark-1.git
cd ~/arm64-benchmark-1
```

### 1) Preconditions

```bash
sudo -n true && echo sudo=passwordless
test -e /dev/kvm && echo kvm=yes
lscpu | egrep 'Model name|Socket|Core|Thread|CPU\(s\)'
```

Need passwordless sudo and kvm. Chip should read **EPYC 9996**.

### 2) Cell bring-up

```bash
cd ~/arm64-benchmark-1/amd
# GH_TOKEN must be set (Contents:Read on danielgraviet/rlp-bench-pin).
export GH_TOKEN="${GH_TOKEN:?set GH_TOKEN}"
./o start
```

Wait until `:8088/health` is ok. Then:

```bash
./o hw
./o pin
./o test
```

Fix any parity fails before the 1k.

### 3) Create-ready 1000

```bash
cd ~/arm64-benchmark-1/amd
./o clean && ./o 1k
tmux attach -t zen5-1k   # optional watch
```

When tmux `zen5-1k` is gone:

```bash
./o status
# confirm END_EXIT=0 in the create-ready log, FC=0
ls -lt daniel-focus-here/zen5-9996-jsonl/ | head
```

### 4) Push results

```bash
cd ~/arm64-benchmark-1
git add daniel-focus-here/zen5-9996-jsonl/
git status
git commit -m "$(cat <<'EOF'
amd 9996: create-ready 1000 after empty-cell bring-up

EOF
)"
git push
```

Add `codex-direction-log/007-amd-9996-create1k-status.md` with ok/fail counts, `ready_wall_s`, create p50, and pin cpus/mems. Do not commit `.env` or auth files.

## After that

Wait for a Mac follow-up direction for create-ready 2000 and/or dense full ladder. Do not start 2k/dense until asked unless 1k is clean and the Mac note says go.

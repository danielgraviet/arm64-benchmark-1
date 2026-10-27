# Direction: AMD EPYC 9996 — create-path fixes ON suite

You are Codex on the AMD vendor box (`daytonaio@165.204.53.121`, clone `~/arm64-benchmark-1`). Work **on-box**. Do not drive load through a laptop SSH tunnel. Mac only pulls graphs after you push JSONL.

Playbook: [`tickets/amd-codex-host.md`](../tickets/amd-codex-host.md). Pack: [`amd/`](../amd/). Target: `--target epyc9996`.

### HARD GATE — host Codex with full shell access

Run this only as `daytonaio` on the DUT (`nigeria-5253-os`), inside tmux `codex`. Cursor Mac / Cursor cloud / Codex **workspace-write** shell sandbox will fail this gate — that is expected.

Codex on this box must execute shells with **`sandbox_mode = danger-full-access`**. Default Codex sandbox blocks `sudo` and `127.0.0.1:8088` even when the TUI is on the DUT.

Start (or restart) Codex like this:

```bash
cd ~/arm64-benchmark-1
export PATH="$HOME/.local/bin:$PATH"
# preferred: persist in ~/.codex/config.toml then:
codex -s danger-full-access
# equivalent one-shot:
# codex --sandbox danger-full-access
```

Before doing anything else in-session:

```bash
id -un                                    # must be daytonaio
hostname                                  # nigeria-5253-os (or this vendor hostname)
sudo -n true && echo sudo=ok              # must print sudo=ok
test -e /dev/kvm && echo kvm=yes
test -w .git/HEAD && echo git=writable
curl -fsS -m 2 http://127.0.0.1:8088/health || echo 'api not up yet (ok before ./o start)'
```

If `sudo` says **no new privileges**: you are in Codex’s shell sandbox. **Stop.** Tell the human to quit this Codex TUI and relaunch with `-s danger-full-access` (config should already set that). Do not patch binaries, do not touch systemd, do not run benchmarks. Leave October JSONL untouched.

If you are not `daytonaio` on this host: same stop.

## Goal (today)

Rebuild **harness PR #2** patched runner/api (not upstream lbrecic PRs), turn create-path fixes **ON**, pin NUMA node 0, then run the methodology suite comparable to Vera / 9575F / 9555P `BASELINE-*-FIXES-*` files.

Prior Oct-20 JSONL under `daniel-focus-here/zen5-9996-jsonl/` is **not** a fixes-ON baseline. Do not relabel it.

Order: build → fixes-on → pin → preflight → startup 1k → ladder → 2k. Push JSONL after each successful phase if wall clock is tight.

Stay in tmux `codex`. Experiments in their own tmux (`zen5-startup`, `zen5-ladder`, `zen5-2k`).

---

## 0) Hygiene + pull

```bash
export PATH="$HOME/.local/bin:/usr/local/go/bin:$PATH"
export UV_NO_SYNC=1
cd ~/arm64-benchmark-1
who
tmux ls || true
git pull
git fetch origin vera-benchmarks-and-data
```

One operator. If someone else is mid-ladder, stop and report.

Do **not** `git checkout vera-benchmarks-and-data` for the whole clone. Keep the tree that has `amd/` + `epyc9996`. Pull methodology assets into the working tree:

```bash
cd ~/arm64-benchmark-1
git checkout origin/vera-benchmarks-and-data -- \
  data/graviton5-cell-20261014/patches \
  data/graviton5-cell-20261014/scripts/fixes-on.sh \
  data/phoenix-e6-cell-20261014/scripts/ph-build-fixes.sh \
  docs/benchmark-methodology.md \
  scripts/host/bench-preflight.sh \
  mpfleet.py
```

Confirm `harness/regions.py` still knows `epyc9996` (it must; do not overwrite it with the older branch file).

Install preflight on PATH:

```bash
sudo install -m0755 scripts/host/bench-preflight.sh /usr/local/bin/bench-preflight
```

---

## 1) Build patched binaries (PR #2 patches only)

Source pin: `daytona/rlp` **`f0611fa13`**, then the harness patches under `data/graviton5-cell-20261014/patches/`. Do **not** apply upstream PRs #3454 / #3366 / #3370 / #3261 / #3269.

```bash
PATCHES=~/arm64-benchmark-1/data/graviton5-cell-20261014/patches
B=$HOME/rlp-build
rm -rf "$B/src-fixes"
mkdir -p "$B/src-fixes" "$B/out-fixes" "$B/logs"

# Prefer an existing ~/rlp clone; otherwise clone.
if [[ -d $HOME/rlp/.git ]]; then
  git -C "$HOME/rlp" fetch --all --tags
  git -C "$HOME/rlp" worktree remove --force "$B/src-fixes" 2>/dev/null || true
  rm -rf "$B/src-fixes"
  git -C "$HOME/rlp" worktree add --detach "$B/src-fixes" f0611fa13
else
  git clone https://github.com/daytonaio/rlp.git "$B/src-fixes"
  git -C "$B/src-fixes" checkout f0611fa13
fi

cd "$B/src-fixes"
git am "$PATCHES"/bench-build/0*.patch
git apply "$PATCHES"/bench-build/zz-uncommitted-working-tree.diff
git apply "$PATCHES"/api-backlog.diff

cd ~/arm64-benchmark-1
bash data/phoenix-e6-cell-20261014/scripts/ph-build-fixes.sh
```

Gate (must all be non-zero):

```bash
O=$HOME/rlp-build/out-fixes
for k in RLP_INITDISK_MODE RLP_CGROUP_POOL RLP_NEIGH_PERMANENT; do
  printf '%-24s runner:%s\n' "$k" "$(grep -c "$k" "$O/rlp-runner")"
done
printf '%-24s api:%s\n' RLP_API_LISTEN_BACKLOG "$(grep -c RLP_API_LISTEN_BACKLOG "$O/rlp-api")"
# FAIL if any count is 0
```

Install (keep stock as `.bak-prepatch`):

```bash
O=$HOME/rlp-build/out-fixes
API_BIN=$(readlink -f /proc/$(pgrep -nx rlp-api)/exe 2>/dev/null || echo /usr/local/bin/rlp-api)
sudo cp -a /usr/local/bin/rlp-runner /usr/local/bin/rlp-runner.bak-prepatch
sudo cp -a "$API_BIN" "${API_BIN}.bak-prepatch"
sudo install -m0755 -o root -g root "$O/rlp-runner" /usr/local/bin/rlp-runner
sudo install -m0755 -o root -g root "$O/rlp-api" "$API_BIN"
sha256sum /usr/local/bin/rlp-runner "$API_BIN" | tee -a /tmp/9996-fixes-bin-sha.txt
echo "runner=$(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) api=$(sha256sum "$API_BIN" | cut -c1-12)" \
  | sudo tee /etc/rlp/BUILD
```

Leave alone: Firecracker v1.16.1, daemon `rlp-rs-0.4.1`, guest `vmlinux-6.8.12-rlp3`.

**Fallback** only if Docker build fails hard: copy x86 runner `739fc73a116d` + api `93fa5e93bf20` from 9575F / atl1node853, still verify `grep -c RLP_CGROUP_POOL` ≠ 0.

---

## 2) Cell config + fixes ON

Confirm / set baseline match **before** `fixes-on.sh`:

```bash
# Runner
grep -E 'RLP_(SNAPSHOTS|VM_CONCURRENCY|NETNS_POOL|FC_SOCK_WAIT|VM_MAXACK)=' /etc/rlp/runner.env || true
# Need: SNAPSHOTS=1, VM_CONCURRENCY=512, NETNS_POOL=2100
# Leave VM_MAXACK at default (256). Do not raise to 2048.
# API
grep -E 'RLP_(BURST_MAX_CPU|BURST_MAX_MEM_MIB|MIN_SCRATCH_MIB)=' /etc/rlp/api.env || true
# Need: BURST_MAX_CPU=1, BURST_MAX_MEM_MIB=4096, MIN_SCRATCH_MIB=16
```

If `RLP_NETNS_POOL` was lowered for smoke, restore **2100** and restart runner — `fixes-on.sh` waits for ≥1995 netns (Vera leftover; harmless at 2100, burns ~30 min if pool is small).

```bash
# Ensure NETNS_POOL=2100
sudo sed -i '/^RLP_NETNS_POOL=/d' /etc/rlp/runner.env
echo 'RLP_NETNS_POOL=2100' | sudo tee -a /etc/rlp/runner.env

# Sock wait is NOT in fixes-on.sh env today — set it now
sudo sed -i '/^RLP_FC_SOCK_WAIT_MS=/d' /etc/rlp/runner.env
echo 'RLP_FC_SOCK_WAIT_MS=30000' | sudo tee -a /etc/rlp/runner.env

# API burst / min scratch
for kv in RLP_BURST_MAX_CPU=1 RLP_BURST_MAX_MEM_MIB=4096 RLP_MIN_SCRATCH_MIB=16; do
  k=${kv%%=*}; sudo sed -i "/^${k}=/d" /etc/rlp/api.env; echo "$kv" | sudo tee -a /etc/rlp/api.env
done

# Snapshots must be on
sudo grep -q '^RLP_SNAPSHOTS=1$' /etc/rlp/runner.env \
  || { sudo sed -i '/^RLP_SNAPSHOTS=/d' /etc/rlp/runner.env; echo 'RLP_SNAPSHOTS=1' | sudo tee -a /etc/rlp/runner.env; }

sudo sed -i '/^RLP_VM_CONCURRENCY=/d' /etc/rlp/runner.env
echo 'RLP_VM_CONCURRENCY=512' | sudo tee -a /etc/rlp/runner.env
```

Kill any leftover `rlp-cpu-weight-floor` scripts (9575F confounder). Then:

```bash
bash ~/arm64-benchmark-1/data/graviton5-cell-20261014/scripts/fixes-on.sh
```

After it returns, confirm live env:

```bash
renv() { sudo tr '\0' '\n' </proc/$(pgrep -nx "$1")/environ | grep -E "$2"; }
renv rlp-runner '^RLP_(INITDISK_MODE|CGROUP_POOL|NEIGH_PERMANENT|FC_SOCK_WAIT_MS|SNAPSHOTS|NETNS_POOL)='
renv rlp-api '^RLP_(API_LISTEN_BACKLOG|BURST_MAX_CPU|BURST_MAX_MEM_MIB|MIN_SCRATCH_MIB)='
ss -ltn 'sport = :8088' | awk 'NR==2{print "backlog_sum",$2+$3}'
# Expect initdisk=nofsync cgroup_pool=1400 neigh=1 sock_wait=30000 snapshots=1 netns=2100
# Expect api backlog=4096 burst cpu/mem as above min_scratch=16
# Expect ss backlog near 4096
```

Wait until netns count is full on **two consecutive** samples (~2100):

```bash
ok=0
for i in $(seq 1 60); do
  n=$(sudo ip netns list 2>/dev/null | wc -l)
  echo "netns=$n"
  if [ "$n" -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi
  sleep 10
done
```

---

## 3) Pin + preflight (before every timed run)

```bash
cd ~/arm64-benchmark-1/amd
./o pin
# Confirm runner Mems_allowed_list / Cpus_allowed_list are node 0.
PID=$(pgrep -nx rlp-runner)
awk '/Cpus_allowed_list|Mems_allowed_list/{print}' /proc/$PID/status
```

If cpuset write is `Permission denied`, **stop and report**. Do not publish unpinned agent numbers as comparable.

```bash
ulimit -n 1048576
cd ~/arm64-benchmark-1
PF=/tmp/preflight-$(date -u +%Y%m%d_%H%M%S)
sudo -E bench-preflight "$PF"
grep -E 'PREFLIGHT|create_path_fixes' "$PF/preflight.txt"
```

Hard gate: line must show **`PREFLIGHT PASS`** and **`create_path_fixes … ON (initdisk=nofsync cgroup_pool=1400 neigh=1 backlog=4096)`**. If PARTIAL/OFF or FAIL, fix and re-run. Do not start the suite.

Warm snapshots (≥2 creates per image) until runner log shows `template=hit`:

```bash
cd ~/arm64-benchmark-1
set -a && . ./.env && set +a
for img in alpine:3.20 dtgraviet/vera-agent-benchmark:v3; do
  for w in 1 2; do
    UV_NO_SYNC=1 MPFLEET_IMAGE=$img \
      uv run python mpfleet.py --target epyc9996 --procs 4 --count 4 --timeout 180 \
      --output /tmp/warm-$(echo $img | tr ':/' '__')-$w.jsonl || true
    # clean between warms
    UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996 || true
  done
done
sudo journalctl -u rlp-runner --since '10 min ago' --no-pager | grep -E 'template=hit|template build ready' | tail -20
```

---

## 4) Recipes

Use localhost API/toolbox. Env + commands match the Slack / atl1 suite. Results land under `/mnt/data/bench/` (or `/tmp/bench` if `/mnt/data` missing) **and** must be copied into `daniel-focus-here/zen5-9996-jsonl/` with **FIXES-ON** in the filename before commit.

```bash
ulimit -n 1048576
BD=$HOME/arm64-benchmark-1
OUT=/mnt/data/bench/suite-epyc9996-FIXES-ON-$(date -u +%Y%m%d_%H%M%S)
# fallback if no /mnt/data:
[[ -d /mnt/data ]] || OUT=$HOME/bench/suite-epyc9996-FIXES-ON-$(date -u +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
T=epyc9996
AGENT=dtgraviet/vera-agent-benchmark:v3
IDLE=alpine:3.20
PY="$BD/.venv/bin/python"
[[ -x $PY ]] || PY="uv run python"
export PYTHONUNBUFFERED=1
```

Prefer a single tmux session for the suite:

```bash
tmux new-session -d -s zen5-fixes-suite "bash -lc 'ulimit -n 1048576; cd ~/arm64-benchmark-1; exec bash'"
# then attach and paste the phase commands, OR drive phases from Codex while watching status
```

### A) Startup 1k — idle ×3, agent ×3

```bash
cd "$BD"
for r in 1 2 3; do
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996 || true
  sleep 2
  sudo -E bench-preflight "$OUT/pf-1000-idle-$r" | tee "$OUT/pf-1000-idle-$r.log"
  grep -q 'PREFLIGHT PASS' "$OUT/pf-1000-idle-$r/preflight.txt"
  grep create_path_fixes "$OUT/pf-1000-idle-$r/preflight.txt"

  set -a && . ./.env && set +a
  export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_HTTP_READ_TIMEOUT_S=120 \
    RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 \
    MPFLEET_IMAGE=$IDLE
  UV_NO_SYNC=1 uv run python mpfleet.py --target $T --procs 16 --count 1000 --timeout 300 \
    --output "$OUT/startup-1000-idle-FIXES-ON-rep$r.jsonl" \
    | tee "$OUT/startup-1000-idle-FIXES-ON-rep$r.log"
done

for r in 1 2 3; do
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996 || true
  sleep 2
  sudo -E bench-preflight "$OUT/pf-1000-agent-$r"
  grep -q 'PREFLIGHT PASS' "$OUT/pf-1000-agent-$r/preflight.txt"

  set -a && . ./.env && set +a
  export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_HTTP_READ_TIMEOUT_S=120 \
    RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 \
    MPFLEET_IMAGE=$AGENT
  UV_NO_SYNC=1 uv run python mpfleet.py --target $T --procs 16 --count 1000 --timeout 300 \
    --output "$OUT/startup-1000-agent-FIXES-ON-rep$r.jsonl" \
    | tee "$OUT/startup-1000-agent-FIXES-ON-rep$r.log"
done
```

After A: copy JSONL into the focus dir and push (see §5).

### B) Throughput ladder — 176 352 704

```bash
UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996 || true
sudo -E bench-preflight "$OUT/pf-ladder-176-704"
set -a && . ./.env && set +a
export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=600
UV_NO_SYNC=1 uv run python main.py --benchmark agent --runner rlp --target $T \
  --snapshot $AGENT --levels 176 352 704 --n 45 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 \
  --rlp-disk 0.015625 --exec-timeout 600 \
  --output "$OUT/ladder-176-704-FIXES-ON.jsonl" \
  | tee "$OUT/ladder-176-704-FIXES-ON.log"
```

### C) 2k — idle ×3, agent ×2, then ladder 2000

```bash
for r in 1 2 3; do
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996 || true
  sudo -E bench-preflight "$OUT/pf-2000-idle-$r"
  set -a && . ./.env && set +a
  export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_HTTP_READ_TIMEOUT_S=1800 \
    RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 \
    MPFLEET_IMAGE=$IDLE
  UV_NO_SYNC=1 uv run python mpfleet.py --target $T --procs 16 --count 2000 --timeout 300 \
    --output "$OUT/startup-2000-idle-FIXES-ON-rep$r.jsonl" \
    | tee "$OUT/startup-2000-idle-FIXES-ON-rep$r.log"
done

for r in 1 2; do
  UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996 || true
  sudo -E bench-preflight "$OUT/pf-2000-agent-$r"
  set -a && . ./.env && set +a
  export RLP_HTTP_MAX_CONNECTIONS=1024 RLP_HTTP_READ_TIMEOUT_S=1800 \
    RLP_WAIT_POLL_START_S=0.25 RLP_WAIT_POLL_FACTOR=1.5 RLP_WAIT_POLL_MAX_S=2.0 \
    MPFLEET_IMAGE=$AGENT
  UV_NO_SYNC=1 uv run python mpfleet.py --target $T --procs 16 --count 2000 --timeout 300 \
    --output "$OUT/startup-2000-agent-FIXES-ON-rep$r.jsonl" \
    | tee "$OUT/startup-2000-agent-FIXES-ON-rep$r.log"
done

UV_NO_SYNC=1 uv run python scripts/phoenix_rlp_cleanup_sandboxes.py --target epyc9996 || true
sudo -E bench-preflight "$OUT/pf-ladder-2000"
set -a && . ./.env && set +a
export RLP_HTTP_MAX_CONNECTIONS=512 RLP_HOLD_CREATE_BATCH=512 RLP_HTTP_READ_TIMEOUT_S=1800
UV_NO_SYNC=1 uv run python main.py --benchmark agent --runner rlp --target $T \
  --snapshot $AGENT --levels 2000 --n 45 --seed 42 -E 8 --hold-then-exec \
  --rlp-cpu 0.025 --rlp-cpu-max 1 --rlp-memory 0.0625 --rlp-memory-max 4 \
  --rlp-disk 0.015625 --exec-timeout 1800 \
  --output "$OUT/ladder-2000-FIXES-ON.jsonl" \
  | tee "$OUT/ladder-2000-FIXES-ON.log"
```

---

## 5) After each successful phase — commit + push

```bash
cd ~/arm64-benchmark-1/amd && ./o status   # or scripts/host/status.sh
# FC=0, no stray experiment tmux if you expect idle

mkdir -p ~/arm64-benchmark-1/daniel-focus-here/zen5-9996-jsonl
cp -v "$OUT"/*FIXES-ON*.jsonl ~/arm64-benchmark-1/daniel-focus-here/zen5-9996-jsonl/

cd ~/arm64-benchmark-1
git add daniel-focus-here/zen5-9996-jsonl/*FIXES-ON*.jsonl
git status
git commit -m "$(cat <<'EOF'
amd 9996: create-path fixes ON methodology results

EOF
)"
git push
```

Never commit `.env`, `amd/.env.amd`, `~/.codex/auth.json`, or binary builds.

Optional status note for the Mac: `codex-direction-log/009-amd-9996-fixes-suite-status.md` with preflight ON line, bin shas, pin cpus/mems, and per-rep `ok` / `ready_wall_s` / create p50.

---

## Gotchas (do not ignore)

- Compare only against `BASELINE-*-FIXES-*`, not older unpatched numbers.
- `fixes-on.sh` deletes `zz-arm.conf` (harmless on x86) and waits for ~1995 netns — restore `NETNS_POOL=2100` first.
- Without `RLP_SNAPSHOTS=1`, every create cold-boots (invalidates the run).
- SSH sessions often cap `nofile` at 524288 — always `ulimit -n 1048576` before preflight.
- Paperspace ATL1 had no guest internet; this AMD cell should have it, but do not add guest downloads into the recipes.
- phoenix-e6 may be in use by another operator — stay on this box.

## Done when

1. Preflight shows create_path_fixes **ON** + sock wait 30000.
2. Runner `grep -c RLP_CGROUP_POOL` ≠ 0.
3. Socket-0 pin confirmed for published agent runs.
4. At least idle+agent 1k ×3 FIXES-ON JSONL pushed; ladder + 2k same day if time allows.

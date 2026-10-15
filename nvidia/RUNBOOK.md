# NVIDIA runbook — single-socket EPYC 9755

Empty Ubuntu server → RLP cell → create 1k → create 2k → dense full ladder.

Chip: **AMD EPYC 9755**, **one socket**. Recipe matches our RedSwitches 9755 path (`--target epyc9755`, dense **n=45**), not the dual-socket vendor-pack n=50 ladder.

Everything you need is under `nvidia/`. Root `./o` is for OCI Vera; ignore it here.

---

## Access checklist (before SSH)

1. Collaborator on this repo (`arm64-benchmark-1`) and on [`danielgraviet/rlp-bench-pin`](https://github.com/danielgraviet/rlp-bench-pin) (standalone private mirror of the RLP bench pin — **not** the enterprise fork).
2. On the box: passwordless `sudo`, `/dev/kvm` present, outbound HTTPS for apt + Docker Hub (and GitHub if using Path A).

`gh` is **not** required. Prefer Path A (PAT + plain `git`) or Path B (tarball / scp / Drive) below.

Do not drive ladders from a laptop SSH tunnel. That measures the tunnel. Run on the box.

---

## Path A — passphrase pack (preferred)

Ciphertext in git. Short password you tell her out of band. Same pattern as OCI Vera.

**You (Mac), once:**

```bash
cd arm64-benchmark-1
export GH_TOKEN='github_pat_…'   # read rlp-bench-pin, write this repo
NVIDIA_PASS='four short words' bash nvidia/scripts/pack_secrets.sh
git add secrets/nvidia-zen5.enc secrets/nvidia-zen5.sha256
git commit -m "nvidia: encrypted secret pack"
git push
```

**Ananya (9755):**

```bash
git clone https://github.com/danielgraviet/arm64-benchmark-1.git
cd arm64-benchmark-1/nvidia
NVIDIA_PASS='four short words' ./o load   # → ../.env.nvidia (gitignored)
./o start
./o hw
./o test
```

Rotate the PAT after the runs. Never commit `.env.nvidia` or `secrets/*.plain`.

## Path A2 — paste PAT on the box

```bash
git clone https://github.com/danielgraviet/arm64-benchmark-1.git
cd arm64-benchmark-1/nvidia
export GH_TOKEN='github_pat_…'
./o start
./o hw
./o test
```

---

## Path B — tarball / scp / Google Drive (no `gh`, no GitHub from the box)

You pack on a machine that *can* reach GitHub; she only extracts.

**On your Mac (once):**

```bash
# harness
git clone --depth 1 https://github.com/danielgraviet/arm64-benchmark-1.git
tar -C "$(dirname arm64-benchmark-1)" -czf arm64-benchmark-1.tgz arm64-benchmark-1

# RLP pin (standalone mirror)
git clone --depth 1 --branch bench-pin https://github.com/danielgraviet/rlp-bench-pin.git rlp
tar -czf rlp-bench-pin.tgz rlp
```

Send both `.tgz` via scp, Drive, USB, etc.

**On the 9755:**

```bash
# example: files landed in ~/inbox
mkdir -p "$HOME"
tar -C "$HOME" -xzf ~/inbox/arm64-benchmark-1.tgz
tar -C "$HOME" -xzf ~/inbox/rlp-bench-pin.tgz   # must extract to ~/rlp
# confirm:
ls "$HOME/rlp/api" "$HOME/rlp/runner" "$HOME/arm64-benchmark-1/nvidia/o"

cd "$HOME/arm64-benchmark-1/nvidia"
# no GH_TOKEN needed when ~/rlp is already present
./o start
./o hw
./o test
```

If `./o start` still asks for a token, force offline: `SKIP_CLONE=1 ./o start`.

---

## One-time bring-up (after Path A or B)

```bash
cd ~/arm64-benchmark-1/nvidia   # or wherever you extracted

./o start             # cell + harness + eng SDK + 9755 tune (long first time)
./o hw                # chip / DIMM / cooling / server inventory
./o test              # Vera-closeness parity + one-sandbox smoke

./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
```

That full sequence is the supported path. All three runs write a `wall_share` line (disk/scratch/mem create phases) into their JSONL. `./o start` will:

- Install apt deps, uv, Go, Rust, Firecracker 1.16.1 (x86_64)
- Clone `~/rlp` from `danielgraviet/rlp-bench-pin` at pin `bench-pin`
- Build `rlp-api` / `rlp-runner` / `rlp-proxy`
- Build amd64 guest kernel + initdisk if missing (`./o k` alone does guest only)
- Start postgres + NATS, systemd units on `:8088` / `:9000`
- Seed region `epyc9755`, mint API key into repo-root `.env`
- `uv sync` + eng editable `rlp-sdk` + create-admission tune

Idempotent resume: if binaries already exist, `./o start` sets `SKIP_BUILD=1`. To force rebuild: `SKIP_BUILD=0 ./o start`.

---

## What “close to Vera” means

`./o check` / `./o test` require the same create/dense knobs we use on Vera:

| Knob | Expect |
|------|--------|
| API / toolbox | `127.0.0.1:8088` / `:9000` |
| Firecracker | ~1.16.1 |
| `RLP_BURST_MAX_CPU` | `1` |
| `RLP_MIN_CPU` / `RLP_MIN_MEM_MIB` | `≤0.025` / `≤64` |
| `RLP_MAX_LIVE_VMS` | `≥2500` |
| `RLP_NETNS_POOL` | `≥2100` |
| Region / guest arch | `epyc9755` / `amd64` |
| Eng SDK | `cpu_max` + `memory_max` + `region_routing` |

Differences from Vera are intentional: region id, amd64 guest names, no Vera socket pin.

---

## Benchmark sequence

Always clean between runs. `./o clean` drains via paginated API DELETE, then fails if Firecracker orphans remain (only then may it `pkill` after live=0).

```bash
./o clean && ./o 1k           # create-ready 1000 → tmux zen5-1k
# wait until tmux session is gone, END_EXIT=0 in the log
./o clean && ./o 2k           # create-ready 2000 → tmux zen5-2k
./o clean && ./o full-ladder  # dense 44→2000 n=45 → tmux zen5-dense2k
```

Attach / watch:

```bash
tmux attach -t zen5-1k
./o status
```

The run wrappers also clean before and after. Running `./o clean && …` still makes the gate explicit.

### Recipes (do not change)

**Create-ready 1k / 2k** — `TARGET=epyc9755` via `scripts/host/run_create_ready.sh`.
JSONL includes client timings (`post_s` / `wait_s` / `create_s` / `probe_s`) plus a scraped `wall_share` record from `rlp-runner` `boot-phases` (scratch/disk copy, memory load, FC start, toolbox wait), same shape as Vera create-ready.

**Full ladder** — same as `scripts/host/run_dense2k.sh`:

- levels `44 88 176 352 528 704 880 1056 1408 1760 2000`
- `--n 45 --seed 42 -E 8 --hold-then-exec`
- `--rlp-cpu 0.025 --rlp-cpu-max 1`
- `--rlp-memory 0.0625 --rlp-memory-max 0.5 --rlp-disk 1`
- image `dtgraviet/vera-agent-benchmark:v3`
- Agent episode metrics **and** a scraped `wall_share` / `phase_p50_ms` from create boot-phases during the ladder (scratch/disk, mem load, FC, toolbox)

After `./o 1k`, `./o 2k`, or `./o full-ladder`, confirm the JSONL has a `type: wall_share` line with `phase_p50_ms.scratch_cp_ms` / `load_ms`.

---

## Artifacts

| What | Where |
|------|--------|
| Create / dense JSONL | `daniel-focus-here/zen5-9755-jsonl/` |
| Dense mirror for EDA | `data/agent/rlp-redswitches-9755-c0p025-max1/` |
| Host inventory | `daniel-focus-here/zen5-9755-jsonl/host_hw_<utc>.{json,md}` and `nvidia/results/` |
| Cell secrets | repo-root `.env` (**never commit**) |

After a clean run (`./o status` shows FC=0, `END_EXIT=0`):

```bash
cd ..   # repo root
git add daniel-focus-here/zen5-9755-jsonl/ data/agent/rlp-redswitches-9755-c0p025-max1/ nvidia/results/
git commit -m "zen5 9755: <1k|2k|dense> results"
git push
```

---

## `./o` verbs

| Verb | Action |
|------|--------|
| `start` | Full cell + client bootstrap |
| `k` | Build amd64 guest only |
| `hw` | Hardware inventory |
| `check` | Parity gate |
| `test` | Parity `--strict` + smoke |
| `clean` | Drain + FC=0 gate |
| `1k` / `2k` | Create-ready in tmux |
| `full-ladder` | Dense ladder in tmux |
| `status` | Disk / FC / health / recent logs |
| `help` | This list |

---

## Do not

- Drive the ladder from a laptop tunnel
- `killall -9 firecracker` before API drain (`./o clean` first)
- Bare `uv sync` without re-running eng SDK install (drops `cpu_max`)
- Reboot because MOTD said restart required
- Change `--n` on the dense ladder (45 is the single-socket recipe)
- Commit `.env`, `.venv`, or Codex auth files

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `GH_TOKEN unset` | Path A: `export GH_TOKEN=…`. Path B: extract `~/rlp` then `SKIP_CLONE=1 ./o start` |
| Guest missing | `./o k` then `./o start` |
| API health fail | `sudo journalctl -u rlp-api -n 80` |
| Smoke 401 | Key in `.env` stale — re-run `./o start` (mint) |
| `[Errno 24]` | `ulimit -n` stuck at 1024 — re-login after `./o start` nofile config |
| `FC>0` after clean | `./o clean` again; if stuck, API live must be 0 first |
| Eng SDK missing `cpu_max` | `bash ../scripts/host/install_eng_rlp_sdk.sh` then keep `UV_NO_SYNC=1` |

Scripts live in `nvidia/scripts/`. They call shared harness helpers under `scripts/host/` and `scripts/phoenix_rlp_cleanup_sandboxes.py` so create/dense logic stays one place.

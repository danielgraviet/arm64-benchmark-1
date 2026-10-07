# OCI Vera bare-cell runbook

Typed-minimal path for the Nix desktop → SSH → Vera node hop. Goal: directional
repro of onsite create-ready (**1000 ≈ 10.8 s**, **2000 ≈ 27 s**) and dense peak
(**~13 jobs/s @ 352**). Exact match not required.

Client stays **on the Vera node**. No laptop tunnel.

Related: `scripts/host/oci` (short commands), `scripts/host/oci_pack_secrets.sh`,
`scripts/host/oci_load_secrets.sh`, `scripts/host/oci_vera_bootstrap.sh`,
`scripts/host/check_vera_parity.sh`, `tickets/vera-pin-single-socket.sh`.

---

## Mac prep (before OCI session)

Paste works on the Mac. Do the long secrets here once.

1. Confirm harness has **no secrets in tracked files** (`.env` is gitignored).
2. Harness is **already public**: `https://github.com/danielgraviet/arm64-benchmark-1`
3. Mint a short-lived GitHub PAT with `contents:read` on private `daytona/rlp`
   (or `danielgraviet/rlp`). Pin is always **`660e6e3b`**.
4. **Pack secrets** (encrypt with a short passphrase you can type on the box):
   ```bash
   cd ~/Desktop/projects/arm64-benchmark-1
   export GH_TOKEN='ghp_…'          # paste OK here
   # optional: export RLP_API_KEY='…'  DOCKERHUB_TOKEN='…'
   OCI_PASS='four short words' bash scripts/host/oci pack
   git add secrets/oci-vera.enc secrets/oci-vera.sha256
   git add scripts/host/ tickets/oci-vera-bare-cell-runbook.md .env.example .gitignore
   git commit -m "oci vera: bootstrap + encrypted secret pack"
   git push
   ```
   Remember the passphrase. That is the only secret you type on Vera.
5. Stage **guest kernel + initdisk** onto the node (not in git), e.g.:
   ```text
   /var/lib/rlp/kernel/Image-arm64
   /var/lib/rlp/kernel/initdisk-arm64.ext4
   ```

Ciphertext in `secrets/oci-vera.enc` is safe to push to the public repo. Plaintext
never is. Use a passphrase you will not reuse elsewhere.

---

## Typed session (on Vera node)

Type almost nothing. Repo-root `./o` is the entrypoint.

### Already cloned (your case right now)

```bash
cd arm64-benchmark-1
git pull
./o r
```

`./o r` deletes a broken/incomplete `~/rlp` (common after a Nix password prompt
interrupted the clone), then boots. Eng SDK pin is branch **`bench-pin`** on
`danielgraviet/rlp` (same commit as `660e6e3b`).

If `~/rlp` is already healthy: `./o g` is enough.

### Fresh box

```bash
git clone https://github.com/danielgraviet/arm64-benchmark-1.git
cd arm64-benchmark-1
OCI_PASS='four words' ./o l
./o g
```

Stage guest kernel/initdisk under `/var/lib/rlp/kernel/` before `./o g` if missing.

Client-only re-run (cell already up): `SKIP_CELL=1 ./o g`

**Stop if API health fails.** Do not start ladders.

### Parity / runs

```bash
./o c
./o s
tmux new -d -s c1k ./o 1
tmux new -d -s c2k ./o 2
tmux new -d -s dense ./o d
./o t
```

Must PASS: `RLP_SNAPSHOTS=1`, `RLP_BURST_MAX_CPU=1`, high live/concurrency, localhost
`VERA_RLP_*`, eng SDK `cpu_max`, FC present.

### 5. Smoke

```bash
bash scripts/host/oci smoke
```

### 6. Optional socket pin (create-ready compare)

Confirm topology first:

```bash
lscpu -p=CPU,CORE,SOCKET,NODE | head
```

Onsite pin was NUMA0 `0-87,176-263`. Only if that map still matches:

```bash
bash tickets/vera-pin-single-socket.sh
```

Otherwise derive cpuset from `lscpu` before quoting create-ready numbers.

### 7. Runs (tmux; keep a separate interactive session)

```bash
tmux new -d -s c1k bash scripts/host/oci c1k
# after clean 1k:
tmux new -d -s c2k bash scripts/host/oci c2k
# dense (long):
tmux new -d -s dense bash scripts/host/oci dense
```

Watch:

```bash
tmux a -t c1k
bash scripts/host/oci status
```

### 8. Push results → Mac graphs

```bash
git add daniel-focus-here/vera-jsonl/*.jsonl data/agent/rlp-vera-c0p025-max1/*.jsonl
git commit -m "oci vera: create-ready / dense JSONL"
git push
```

On the Mac: `git pull` then plot via `daniel-focus-here/plotting/`.

Use a **repo-local** credential helper for push. Never `git config --global credential.helper`.

---

## Parity checklist (onsite knobs)

| Layer | Knob | Value |
| --- | --- | --- |
| runner | `RLP_SNAPSHOTS` | `1` |
| api | `RLP_BURST_MAX_CPU` | `1` |
| api | `RLP_MIN_CPU` / `RLP_MIN_MEM_MIB` | `0.025` / `64` |
| runner | `RLP_VM_CONCURRENCY` | ≥ 128 (bootstrap sets 256) |
| runner | `RLP_MAX_LIVE_VMS` | ≥ 2500 (bootstrap 3000) |
| runner | `RLP_NETNS_POOL` | ≥ 2100 |
| host | neigh `gc_thresh3` | ≥ 16384 (bootstrap 65536) |
| host | `ulimit -n` | 65536 create / 1048576 dense |
| client | `VERA_RLP_*` | localhost `:8088` / `:9000/toolbox` |
| client | eng SDK | `@660e6e3b` + fractional `mem_mib` |
| client | image | `dtgraviet/vera-agent-benchmark:v3` |
| create 1k | HTTP pool | 1024 |
| create 2k | HTTP pool | 4096 |
| dense | cpu/mem | `0.025`/`max1`, mem `0.0625`/`max4`, n=45, levels 44→2000 |

---

## Failure table

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `git clone` RLP 401/404 | Private repo, no token | `GH_TOKEN=…` or use `RLP_GIT_URL=` fork you can read |
| `RLP_KERNEL missing` | Guest artifacts not staged | Copy Image + initdisk; re-run bootstrap |
| `:8088` refused | API/build failed | `journalctl -u rlp-api -n 80 --no-pager` |
| toolbox 000 / port busy | MinIO stole `:9000` | Bootstrap only starts `postgres nats`; stop MinIO |
| `no matching capacity` / pickup 60s | Low concurrency or no region | Raise `RLP_VM_CONCURRENCY`; ensure `regions.id=vera` |
| Slow create-ready, template=miss | Snapshots off | `RLP_SNAPSHOTS=1` + restart runner |
| Guests huge / host pegged | Burst default 16 | `RLP_BURST_MAX_CPU=1` + restart api |
| ARP / toolbox stalls at ~1k | neigh table | re-run neigh sysctls in bootstrap / tune script |
| FC snapshot load 400 | FC version skew | Firecracker **1.16.1** only |
| Hub pull hangs | Docker Hub blocked | See Hub fallback below |
| SDK missing `cpu_max` | PyPI overlay lost | `bash scripts/host/install_eng_rlp_sdk.sh`; always `UV_NO_SYNC=1` |
| Tunnel-flat throughput | Client not on node | Run wrappers on Vera SSH session only |

---

## Hub image fallback

Required image: `dtgraviet/vera-agent-benchmark:v3` (multi-arch).

If Hub is blocked from the node, on a machine that can pull:

```bash
docker pull dtgraviet/vera-agent-benchmark:v3
docker save dtgraviet/vera-agent-benchmark:v3 | gzip > vera-agent-v3.tar.gz
```

Transfer the tarball onto the Vera node (approved OCI Object Storage / USB / scp via
jump), then:

```bash
gunzip -c vera-agent-v3.tar.gz | sudo docker load
```

RLP still needs the layers reachable from the runner CAS path; if the cell pulls
via containerd/docker integration, `docker load` may be enough for first create.
If creates still miss layers, ask eng how this cell imports Hub digests into CAS.

---

## Success bar (directional)

- Create-ready 1000: **1000/1000**, wall toward ~11–15 s once cell is healthy
- Create-ready 2000: **2000/2000**, mid-tens of seconds (onsite 27 s)
- Dense: clean peak near mid-teens jobs/s at 352–704; exact 13.3 not required

---

## RLP pin note

Do **not** republish proprietary `daytona/rlp`. Do **not** float to `main`.
Operator pin is always **`660e6e3b`** (same as `scripts/host/install_eng_rlp_sdk.sh`).
`danielgraviet/rlp` is only a private clone mirror / fallback URL.

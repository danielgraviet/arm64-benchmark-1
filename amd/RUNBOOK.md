# AMD EPYC 9996 runbook — empty Ubuntu → results

Empty vendor Ubuntu → RLP cell → create 1k → create 2k → dense full ladder.

Chip: **AMD EPYC 9996**, **two sockets** × 256 cores (1024 logical CPUs, 4 NUMA nodes). Timed compares pin to **NUMA node 0** (`./o pin`) so numbers stay fair vs Vera / 9575F / 9755.

Everything you need is under `amd/`. Root `./o` is OCI Vera. `nvidia/o` is 9755. Do not cross-wire.

---

## Access checklist (before SSH)

1. Collaborator on this repo and on [`danielgraviet/rlp-bench-pin`](https://github.com/danielgraviet/rlp-bench-pin).
2. On the box: passwordless `sudo` (`sudo -n true`), `/dev/kvm`, outbound HTTPS for apt + Docker Hub + GitHub.
3. User: `daytonaio@165.204.53.121 -p 30208`. Mac helpers: `amd/ssh` + gitignored `amd/.env.amd`.

Do not drive ladders from a laptop SSH tunnel. Run on the box.

---

## Path A — GH_TOKEN on the box (simplest)

```bash
git clone https://github.com/danielgraviet/arm64-benchmark-1.git
cd arm64-benchmark-1/amd
export GH_TOKEN='github_pat_…'   # read rlp-bench-pin, write this repo
./o start
./o hw && ./o pin && ./o test
./o clean && ./o 1k
```

Or put `GH_TOKEN=…` in `amd/.env.amd` / repo-root `.env.amd` (gitignored) so `./o start` picks it up.

You can also reuse a decrypted `.env.nvidia` on the box if it already has `GH_TOKEN`.

---

## Codex operator loop

Preferred after first bring-up. See [`tickets/amd-codex-host.md`](../tickets/amd-codex-host.md).

1. Mac: edit `codex-direction-log/NNN-*.md`, commit, push.
2. Box `tmux attach -t codex`: `git pull`, Codex follows the note.
3. Experiments in their own tmux (`zen5-1k`, etc.). Never kill `codex` for that.
4. Commit JSONL under `daniel-focus-here/zen5-9996-jsonl/`, push. Mac pulls to graph.

---

## Typed commands

```bash
cd amd
./o help
./o start          # cell + harness + eng SDK + tune_epyc9996_create
./o hw
./o pin            # node 0
./o test           # pin + parity + smoke
./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
./o status
```

Target: `--target epyc9996`. Localhost API `:8088`, toolbox `:9000`.

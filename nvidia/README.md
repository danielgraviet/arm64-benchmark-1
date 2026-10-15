# NVIDIA Zen5 (single-socket EPYC 9755)

**Start here → [RUNBOOK.md](RUNBOOK.md)**

This directory is the only place NVIDIA eng needs for the empty-Ubuntu bare-cell path on a single-socket 9755.

```bash
cd nvidia
# Preferred: NVIDIA_PASS='…' ./o load   (Mac packed secrets/nvidia-zen5.enc)
# Or:        export GH_TOKEN='…'
./o start
./o hw
./o test
./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
```

See [RUNBOOK.md](RUNBOOK.md) for passphrase pack, PAT paste, and tarball bring-up.

| Command | What it does |
|---------|----------------|
| `./o start` | Clone RLP fork, build cell, mint key, harness + eng SDK |
| `./o hw` | Chip / RAM / cooling / server inventory |
| `./o test` | Parity vs Vera knobs + one-sandbox smoke |
| `./o clean` | Drain sandboxes; fail if Firecracker orphans remain |
| `./o 1k` / `./o 2k` | Create-ready 1000 / 2000 (tmux) |
| `./o full-ladder` | Dense agent ladder 44→2000, n=45 (tmux) |

Root `./o` is OCI Vera-only. Do not use it on this box.

Results land under `daniel-focus-here/zen5-9755-jsonl/` (and copies of hw under `nvidia/results/`).

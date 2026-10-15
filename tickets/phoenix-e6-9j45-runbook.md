# OCI Phoenix E6 / EPYC 9J45 — agent-operated bench

Dual-socket **AMD EPYC 9J45** cell (`vedran-test`, region **`phoenix-e6`**, cpu type **`turin-9j45`**).

Access: `ssh -l ubuntu 158.101.39.4`

Eng already built the cell (do **not** reseed as `epyc9755`). Operator path is `nvidia/o` with auto `SKIP_CELL=1` + socket-0 pin.

## Recipe (match Vera / 9755 focus pack)

- Create-ready 1000 + 2000 (`0.025` cpu, `0.0625` mem, disk 1, image `:v3`)
- Dense `44→2000`, `--n 45`, `-E 8`, `--hold-then-exec`, `--rlp-cpu 0.025 --rlp-cpu-max 1`, mem `0.0625`/`0.5`
- **Socket 0 pin** before timed runs: cpuset from `/sys/devices/system/node/node0/cpulist` (typically `0-95,192-287`), mems `0`
- Metrics: `host_hw_*.json`, populated `socket_pin` on create meta, `wall_share` boot-phases on create + dense

## Agent sequence (human does nothing on the box)

```bash
# preserve key, replace stale non-git tree if needed
cp ~/arm64-benchmark-1/.env /tmp/phoenix-e6.env
# fresh clone of arm64-benchmark-1, restore .env
cd ~/arm64-benchmark-1/nvidia
./o start          # SKIP_CELL=1 harness + eng SDK
./o hw
./o pin            # socket 0
./o test           # parity (incl. pin) + smoke
./o clean && ./o 1k
./o clean && ./o 2k
./o clean && ./o full-ladder
```

Results:

- `daniel-focus-here/zen5-9j45-jsonl/`
- `data/agent/rlp-phoenix-e6-c0p025-max1/`
- `nvidia/results/` (hw copies)

Never commit `.env`.

## Pin

```bash
bash tickets/9j45-pin-single-socket.sh 0     # or: cd nvidia && ./o pin
bash tickets/9j45-pin-single-socket.sh undo
```

Same model as `tickets/vera-pin-single-socket.sh` (whole `rlp.slice` + `vms` on one NUMA node).

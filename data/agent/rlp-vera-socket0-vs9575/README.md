# Vera single-socket (NUMA node0) vs 9575F-matched recipe

- Date: 2026-09-06
- Host: ipp8-d15-c2-vera-1, cpuset pinned to NUMA node0 (`0-87,176-263`)
- Recipe: agent · rlp · `--n 50 --seed 42 -E 8 --hold-then-exec --rlp-cpu 0.125 --rlp-cpu-max 1`
- Levels: `1 8 22 44 88 132 176 264 352`
- Snapshot: `dtgraviet/vera-agent-benchmark:v3`
- JSONL: `../rlp-vera-c0p125-max1/concurrency_20260906_134405_n50.jsonl`
- Log: `vera-socket0-vs9575-20260906T134400Z.log`
- Exit: 0 · failures: 0 all levels

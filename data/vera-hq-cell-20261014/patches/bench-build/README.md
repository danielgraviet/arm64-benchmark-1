# Exact build running on the HQ Vera bench cell

Recreate the runner with:

    git checkout f0611fa13
    git am 0*.patch                              # local commits (EROFS -b 4096 cherry-pick, RLP_FC_SMT, ...)
    git apply zz-uncommitted-working-tree.diff   # RLP_FC_SOCK_WAIT_MS knob + the four measured fixes
    cd runner && CGO_ENABLED=0 go build -trimpath -o rlp-runner ./cmd/runner

The API is `f0611fa13`'s `api/` plus `../api-backlog.diff` (built on the cell with Rust 1.99).

Flags added by the working-tree diff, every one defaulting to stock behaviour:
- `RLP_FC_SOCK_WAIT_MS` (default 3000): Firecracker API-socket wait (#3212)
- `RLP_INITDISK_MODE` = copy (default) | nofsync | sparse (#3260)
- `RLP_CGROUP_POOL` = size, 0 = off; `RLP_CGROUP_POOL_FILLERS` (default 8) (#3261)
- `RLP_NEIGH_PERMANENT` = 1 to enable (#3265)
- `RLP_API_LISTEN_BACKLOG` (API, default 128) (#3269)

Deployed binaries: runner `0fd55bab4ad6`, api `1648ab971fe5`. Stock binaries on the cell:
`/usr/local/bin/rlp-runner.bak-prepatch` (`353a4060945c`), `/opt/rlp/rlp-api.bak-prepatch` (`c49d24e5ac54`).

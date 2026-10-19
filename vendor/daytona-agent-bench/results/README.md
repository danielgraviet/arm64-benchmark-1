This directory starts empty of real runs.

`scripts/run_ladder.sh` writes **`agent_hold_then_exec.jsonl`**. That is the file to send back.

A previous run is copied to `agent_hold_then_exec_<UTC>.jsonl` so a rerun does not clobber.

`schema.example.jsonl` is a fake three-line shape only. It is not a result.

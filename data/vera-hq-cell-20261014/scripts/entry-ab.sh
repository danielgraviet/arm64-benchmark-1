#!/bin/bash
# Entrypoint A/B: agent image (entrypoint runs workload.agent, ~3 core-s/sandbox) vs alpine (idle), pinned/unpinned.
A=dtgraviet/vera-agent-benchmark:v3; B=alpine:3.20
for spec in "AGENT PIN $A" "ALPINE PIN $B" "AGENT UNPIN $A" "ALPINE UNPIN $B" "ALPINE PIN $B" "AGENT PIN $A" "ALPINE UNPIN $B" "AGENT UNPIN $A"; do
  set -- $spec; TAG=$1-$2 PLACE=$2 IMG=$3 bash ~/cpu-burst.sh > /dev/null 2>&1
done
echo "$(date -u +%T) entry-ab DONE" >> /mnt/data/bench/entry-ab.done

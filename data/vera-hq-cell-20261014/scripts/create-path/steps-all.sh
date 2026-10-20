#!/bin/bash
S=/home/daytona/steps
bash $S/steps-run.sh burst-alpine-1 burst 1000 alpine:3.20 16
bash $S/steps-run.sh burst-alpine-2 burst 1000 alpine:3.20 16
bash $S/steps-run.sh burst-agent    burst 1000 dtgraviet/vera-agent-benchmark:v3 16
bash $S/steps-run.sh seq-agent      seq   100  dtgraviet/vera-agent-benchmark:v3
echo "$(date -u +%T) steps-all DONE" > /mnt/data/bench/steps-all.done

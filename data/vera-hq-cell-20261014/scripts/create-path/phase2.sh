#!/bin/bash
S=/home/daytona/steps
ALLN="RLP_INITDISK_MODE=nofsync;RLP_CGROUP_POOL=1400;RLP_NEIGH_PERMANENT=1"
ALLS="RLP_INITDISK_MODE=sparse;RLP_CGROUP_POOL=1400;RLP_NEIGH_PERMANENT=1"
BL="RLP_API_LISTEN_BACKLOG=4096"
bash $S/arm.sh all-n1  burst 1000 "$ALLN" "$BL"
bash $S/arm.sh ctl-3   burst 1000 "" ""
bash $S/arm.sh all-s1  burst 1000 "$ALLS" "$BL"
bash $S/arm.sh all-n2  burst 1000 "$ALLN" "$BL"
bash $S/arm.sh seq-ctl seq   60   "" ""
bash $S/arm.sh seq-nei seq   60   "RLP_NEIGH_PERMANENT=1" ""
bash $S/arm.sh seq-all seq   60   "$ALLN" "$BL"
echo PHASE2-DONE

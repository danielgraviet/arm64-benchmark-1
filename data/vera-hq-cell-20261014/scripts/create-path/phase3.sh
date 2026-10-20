#!/bin/bash
S=/home/daytona/steps
ALLN="RLP_INITDISK_MODE=nofsync;RLP_CGROUP_POOL=1400;RLP_NEIGH_PERMANENT=1"
ALLS="RLP_INITDISK_MODE=sparse;RLP_CGROUP_POOL=1400;RLP_NEIGH_PERMANENT=1"
BL="RLP_API_LISTEN_BACKLOG=4096"
bash $S/arm.sh all-n3 burst 1000 "$ALLN" "$BL"
bash $S/arm.sh ctl-4  burst 1000 "" ""
bash $S/arm.sh all-s2 burst 1000 "$ALLS" "$BL"
bash $S/arm.sh all-n4 burst 1000 "$ALLN" "$BL"
echo PHASE3-DONE

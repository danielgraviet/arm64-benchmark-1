#!/bin/bash
S=/home/daytona/steps
bash $S/arm.sh ctl-1    burst 1000 "" ""
bash $S/arm.sh nofsync  burst 1000 "RLP_INITDISK_MODE=nofsync" ""
bash $S/arm.sh sparse   burst 1000 "RLP_INITDISK_MODE=sparse" ""
bash $S/arm.sh cgpool   burst 1000 "RLP_CGROUP_POOL=1400" ""
bash $S/arm.sh backlog  burst 1000 "" "RLP_API_LISTEN_BACKLOG=4096"
bash $S/arm.sh ctl-2    burst 1000 "" ""
echo PHASE1-DONE

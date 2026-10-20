S=/home/daytona/steps
for r in 1 2; do
  a=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  STEP_PREWARM=1 bash $S/steps-run.sh burst-alpine-prewarm-$r burst 1000 alpine:3.20 16 > $S/prewarm-$r.out 2>&1
  b=$(nstat -az TcpExtListenOverflows | tail -1 | awk '{print $2}')
  echo "prewarm rep$r (listen overflows during run incl. prewarm: $((b-a))):"; grep -E "^1 |^2 |^3 |^4 |^5 |POST -> client sees running" $S/prewarm-$r.out
done

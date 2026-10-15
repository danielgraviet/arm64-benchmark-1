#!/bin/bash
set -u
H=/etc/rlp/HOSTCHANGES; touch $H
systemctl stop rlp-runner rlp-api
[ -e /usr/local/bin/rlp-runner.bak-prepatch ] || cp -a /usr/local/bin/rlp-runner /usr/local/bin/rlp-runner.bak-prepatch
[ -e /usr/local/bin/rlp-api.bak-prepatch ] || cp -a /usr/local/bin/rlp-api /usr/local/bin/rlp-api.bak-prepatch
install -m 755 /tmp/rlp-runner-bench /usr/local/bin/rlp-runner
install -m 755 /root/rlp-bench-src/api/target/release/rlp-api /usr/local/bin/rlp-api
# common to both arms, as on HQ Vera: 30 s Firecracker API-socket wait (daytona/rlp#3212)
echo "RLP_FC_SOCK_WAIT_MS=30000" > /etc/rlp/bench-common-runner.env
printf '[Service]\n# both arms, as on HQ Vera (daytona/rlp#3212)\nEnvironmentFile=/etc/rlp/bench-common-runner.env\n' > /etc/systemd/system/rlp-runner.service.d/15-bench-common.conf
systemctl daemon-reload; systemctl start rlp-api; sleep 3; systemctl start rlp-runner
for i in $(seq 1 120); do curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 1; done
ok=0; for i in $(seq 1 180); do n=$(ip netns list 2>/dev/null | wc -l); if [ "$n" -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
echo "runner $(sha256sum /usr/local/bin/rlp-runner | cut -c1-12) (stock $(sha256sum /usr/local/bin/rlp-runner.bak-prepatch | cut -c1-12))"
echo "api    $(sha256sum /usr/local/bin/rlp-api | cut -c1-12) (stock $(sha256sum /usr/local/bin/rlp-api.bak-prepatch | cut -c1-12))"
echo "active: runner=$(systemctl is-active rlp-runner) api=$(systemctl is-active rlp-api) netns=$(ip netns list | wc -l) backlog=$(ss -ltn 'sport = :8088' | awk 'NR==2{print $2+$3}') sockwait=$(tr '\0' '\n' </proc/$(pgrep -nx rlp-runner)/environ | grep -oP '^RLP_FC_SOCK_WAIT_MS=\K.*')"
journalctl -u rlp-api --since -3min --no-pager -o cat | grep -iE "accept backlog|error|panic" | tail -3
echo "$(date -u +%FT%TZ) deployed bench build (f0611fa13 + bench patches, same as HQ Vera; runner $(sha256sum /usr/local/bin/rlp-runner | cut -c1-12), api $(sha256sum /usr/local/bin/rlp-api | cut -c1-12)); stock kept as *.bak-prepatch; 15-bench-common.conf RLP_FC_SOCK_WAIT_MS=30000. Fix flags OFF." >> $H

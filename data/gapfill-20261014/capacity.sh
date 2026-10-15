#!/bin/bash
# capacity.sh raise|restore — runner caps for the idle-density ceiling (phase C). Generalized from phoenix-e6's ph-capacity.sh.
#   raise:   NETNS_POOL -> 6200, MAX_LIVE_VMS -> 8000, SUBNET_CIDR -> $CEIL_CIDR (a /20 caps the host at 4094 sandboxes)
#   restore: the values saved in /etc/rlp/runner.env.pre-capacity
# Needs the runner stopped and all netns + rlp_* nft tables gone (CIDR change). The pool refill burns all CPUs for ~15-20 min
# (phoenix-e6 dropped off the network for ~15 min during it) — on HQ Vera the reverse tunnel may need a restart afterwards.
set -euo pipefail
MODE=${1:?raise|restore}; CEIL_CIDR=${CEIL_CIDR:-10.102.0.0/18}
say() { echo "[$(date -u +%T)] $*"; }
E=/etc/rlp/runner.env
if [ $MODE = raise ]; then
  ip -4 route | grep -q "${CEIL_CIDR%.*}" && { echo "CEIL_CIDR $CEIL_CIDR overlaps an existing route — pick another"; exit 1; }
  [ -e $E.pre-capacity ] || sudo cp -a $E $E.pre-capacity
fi
say "stopping runner"; sudo systemctl stop rlp-runner; sleep 3; sudo pkill -x firecracker 2>/dev/null || true; sleep 2
for ns in $(sudo ip netns list | awk '{print $1}'); do sudo ip netns del "$ns" 2>/dev/null || true; done
sudo nft list tables 2>/dev/null | grep ' rlp_' | while read -r _ fam name; do sudo nft delete table "$fam" "$name" 2>/dev/null || true; done
sudo rm -rf /run/fc/* 2>/dev/null || true
if [ $MODE = raise ]; then
  sudo sed -i -e 's|^RLP_NETNS_POOL=.*|RLP_NETNS_POOL=6200|' -e 's|^RLP_MAX_LIVE_VMS=.*|RLP_MAX_LIVE_VMS=8000|' -e "s|^RLP_SUBNET_CIDR=.*|RLP_SUBNET_CIDR=$CEIL_CIDR|" $E
  WANT=6100
else
  sudo cp -a $E.pre-capacity $E; WANT=$(( $(grep -oP '^RLP_NETNS_POOL=\K.*' $E) - 100 ))
fi
sudo grep -E '^RLP_(NETNS_POOL|MAX_LIVE_VMS|SUBNET_CIDR)=' $E
echo "$(date -u +%FT%TZ) capacity.sh $MODE: $(sudo grep -E '^RLP_(NETNS_POOL|MAX_LIVE_VMS|SUBNET_CIDR)=' $E | tr '\n' ' ')" | sudo tee -a /etc/rlp/HOSTCHANGES >/dev/null
say "starting runner; waiting for the netns pool to refill"
sudo systemctl start rlp-runner
for i in $(seq 1 360); do n=$(sudo ip netns list | wc -l); [ "$n" -ge $WANT ] && break; [ $((i % 30)) = 0 ] && say "  netns=$n"; sleep 5; done
say "netns=$(sudo ip netns list | wc -l) runner=$(systemctl is-active rlp-runner); waiting for load < 5"
for i in $(seq 1 90); do l=$(cut -d' ' -f1 /proc/loadavg); [ "${l%%.*}" -lt 5 ] && break; sleep 10; done
say "load=$(cut -d' ' -f1-3 /proc/loadavg)"

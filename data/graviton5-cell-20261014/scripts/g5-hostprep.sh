#!/bin/bash
# Graviton5 bench host prep (mirrors HQ Vera cell prep). Every change logged to /etc/rlp/HOSTCHANGES.
set -euo pipefail
sudo mkdir -p /etc/rlp && sudo chmod 750 /etc/rlp
C=/etc/rlp/HOSTCHANGES
note() { echo "$(date -u +%FT%TZ) $*" | sudo tee -a $C >/dev/null; echo "$*"; }
# 0) hostname must resolve locally (RedSwitches lesson: sudo blocked on DNS)
H=$(hostname); grep -qw "$H" /etc/hosts || { sudo cp -p /etc/hosts /etc/hosts.bak-rlp; echo "127.0.1.1 $H" | sudo tee -a /etc/hosts >/dev/null; note "/etc/hosts: added 127.0.1.1 $H (backup /etc/hosts.bak-rlp)"; }
# 1) packages: docker + runner host packages (bootstrap-aws-runner.sh list) + tools
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io nftables iproute2 iptables conntrack e2fsprogs erofs-utils libcap2-bin util-linux xfsprogs jq tmux numactl linux-tools-common linux-tools-$(uname -r) sysstat >/dev/null || \
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io nftables iproute2 iptables conntrack e2fsprogs erofs-utils libcap2-bin util-linux xfsprogs jq tmux numactl sysstat >/dev/null
sudo usermod -aG docker $USER || true
note "apt: installed docker.io nftables iptables conntrack erofs-utils xfsprogs jq tmux numactl sysstat (+linux-tools if available)"
echo "erofs-utils $(dpkg -l erofs-utils | awk '/^ii/{print $3}')  docker $(docker --version)"
# 2) sysctl: same as HQ Vera /etc/sysctl.d/90-rlp-bench.conf
sudo tee /etc/sysctl.d/90-rlp-bench.conf >/dev/null <<'S'
# rlp bench cell (Graviton5). Density limits: default ARP table caps a host at ~1k sandboxes.
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536
net.netfilter.nf_conntrack_max = 1048576
net.ipv4.tcp_max_syn_backlog = 65535
vm.max_map_count = 1048576
vm.nr_hugepages = 0
S
sudo modprobe nf_conntrack || true
sudo sysctl -q -p /etc/sysctl.d/90-rlp-bench.conf
note "wrote /etc/sysctl.d/90-rlp-bench.conf (ARP 65536 v4+v6, conntrack 1M, syn backlog, max_map_count, hugepages 0) and applied"
# 3) udev: open-iscsi rule forks a handler for every sandbox veth (OCI/HQ Vera lesson)
if [ -f /usr/lib/udev/rules.d/70-iscsi-network-interface.rules ]; then
sudo tee /etc/udev/rules.d/70-iscsi-network-interface.rules >/dev/null <<'R'
# rlp bench: shadows /usr/lib/udev/rules.d/70-iscsi-network-interface.rules.
# The stock rule forks net-interface-handler for EVERY net device, incl. thousands of sandbox veths.
SUBSYSTEM=="net", KERNEL=="rlp*|veth*|tap*|fc*", GOTO="rlp_iscsi_end"
SUBSYSTEM=="net", ACTION=="add", RUN+="/usr/lib/open-iscsi/net-interface-handler start"
SUBSYSTEM=="net", ACTION=="remove", RUN+="/usr/lib/open-iscsi/net-interface-handler stop"
LABEL="rlp_iscsi_end"
R
sudo udevadm control --reload
note "udev: shadowed 70-iscsi-network-interface.rules to skip rlp*/veth*/tap*/fc* (remove /etc/udev/rules.d/70-iscsi-network-interface.rules to revert)"
fi
# 4) Firecracker v1.16.1 aarch64 (sha pinned, same binary as HQ Vera)
mkdir -p ~/rlp-build/out ~/rlp-build/logs ~/rlp-build/bin
cd /tmp && curl -fsSL https://github.com/firecracker-microvm/firecracker/releases/download/v1.16.1/firecracker-v1.16.1-aarch64.tgz | tar xz
sha=$(sha256sum release-v1.16.1-aarch64/firecracker-v1.16.1-aarch64 | cut -d' ' -f1)
[ "$sha" = 71ca0733576579a75cef268a8fd0ae0629b761b9844559c611f144132ac6038a ] && echo "firecracker sha OK" || { echo "FIRECRACKER SHA MISMATCH $sha"; exit 1; }
cp release-v1.16.1-aarch64/firecracker-v1.16.1-aarch64 ~/rlp-build/out/firecracker
echo PREP-DONE

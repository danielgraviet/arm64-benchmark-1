#!/bin/bash
echo "===BUILD"; sudo cat /etc/rlp/BUILD
echo "===HOSTCHANGES"; sudo cat /etc/rlp/HOSTCHANGES
for f in api.env runner.env proxy.env regions.json; do echo "===$f"; sudo cat /etc/rlp/$f | sed -E 's/(TOKEN|PASSWORD|KEY|rlp:)[^@ ]*/\1****/g'; done
echo "===sysctl"; cat /etc/sysctl.d/90-rlp-bench.conf
echo "===udev"; cat /etc/udev/rules.d/70-iscsi-network-interface.rules 2>/dev/null
echo "===binaries"; sha256sum /usr/local/bin/rlp-runner /usr/local/bin/rlp-proxy /usr/local/bin/rlp-fcns /usr/local/bin/firecracker /opt/rlp/rlp-api
echo "===host"; lscpu | grep -E "Model name|^CPU\(s\)|Thread|Core|Socket|NUMA node[01] CPU"; free -g | sed -n 2p; findmnt -no FSTYPE,SOURCE,SIZE /mnt/data; uname -r

#!/bin/bash
# TEMP: sandbox egress SNAT to the routed public /32 (works around runner masquerade picking bond0's private address).
set -e
PUBLIC_IP=${PUBLIC_IP:?set PUBLIC_IP to the host public /32}
nft -f - <<EOF
table ip rlp_test_snat {
  chain post {
    type nat hook postrouting priority 99;
    ip saddr 10.140.0.0/20 oifname "bond0" ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to $PUBLIC_IP
  }
}
EOF
nft list table ip rlp_test_snat | grep snat
echo "$(date -u +%FT%TZ) (previous line's table failed to parse; applied now) TEMP nft table ip rlp_test_snat applied; remove with: nft delete table ip rlp_test_snat" >> /etc/rlp/HOSTCHANGES

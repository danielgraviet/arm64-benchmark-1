# Read-only: neighbour state for the guest IP + tap counters in a sample of pool netns.
sudo ip netns list | awk '{print $1}' | shuf -n 60 --random-source=/dev/zero > /tmp/ns.txt
for ns in $(cat /tmp/ns.txt); do
  st=$(sudo ip netns exec $ns ip -4 neigh show dev rlptap0 2>/dev/null | awk '{print $NF}' | tr '\n' ',')
  drop=$(sudo ip netns exec $ns cat /sys/class/net/rlptap0/statistics/tx_dropped 2>/dev/null)
  car=$(sudo ip netns exec $ns cat /sys/class/net/rlptap0/carrier 2>/dev/null)
  echo "${st:-none} drop=${drop:-?} carrier=${car:-?}"
done | sed -E 's/drop=[1-9][0-9]*/drop>0/' | sort | uniq -c | sort -rn
echo "neigh params (one ns): $(sudo ip netns exec $(head -1 /tmp/ns.txt) sysctl -n net.ipv4.neigh.rlptap0.retrans_time_ms net.ipv4.neigh.rlptap0.mcast_solicit net.ipv4.neigh.rlptap0.ucast_solicit net.ipv4.conf.rlptap0.arp_accept 2>&1 | tr '\n' ' ')"

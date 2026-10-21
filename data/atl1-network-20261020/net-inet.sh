#!/bin/bash
# Internet test from each atl1 node (IPv4 only: the nodes have no global IPv6). Run locally; orchestrates over ssh.
#   1. egress identity (Cloudflare trace) + latency (ping x50) to nearby, US and EU destinations; mtr to 8.8.8.8 once
#   2. HTTP download, 1 stream, 15 s cap, per endpoint
#   3. HTTP download, 16 parallel streams for 15 s (Hetzner Ashburn, Linode Atlanta)
#   4. iperf3 to Clouvider Atlanta (public server, ports 5201-5209): download (-R) and upload, 1 and 8 streams
#   5. HTTP upload to Cloudflare, 1 and 8 parallel 100 MB POSTs
#   6. all five nodes at once: 16-stream download (Hetzner Ashburn) + iperf3 download from Clouvider, to find a shared cap
set -u
OUT=/tmp/opencode/net/inet-$(date -u +%Y%m%d_%H%M%S); mkdir -p $OUT
declare -A PUB=([853]="${NODE853_PUB:-<node853-public>}" [864]="${NODE864_PUB:-<node864-public>}" [861]="${NODE861_PUB:-<node861-public>}" [865]="${NODE865_PUB:-<node865-public>}" [857]="${NODE857_PUB:-<node857-public>}")
NODES="853 864 861 865 857"
S() { timeout ${T:-400} ssh -o BatchMode=yes root@${PUB[$1]} "$2"; }
say() { echo "$(date -u +%T) $*" | tee -a $OUT/summary.txt; }
DL="cloudflare=https://speed.cloudflare.com/__down?bytes=1000000000
hetzner-ash=https://ash-speed.hetzner.com/10GB.bin
linode-atl=https://speedtest.atlanta.linode.com/1GB-atlanta.bin
vultr-atl=https://ga-us-ping.vultr.com/vultr.com.1000MB.bin
linode-newark=https://speedtest.newark.linode.com/1GB-newark.bin
hetzner-hil=https://hil-speed.hetzner.com/10GB.bin
ovh-fr=https://proof.ovh.net/files/10Gb.dat
hetzner-fsn=https://fsn1-speed.hetzner.com/10GB.bin"
PING="1.1.1.1 8.8.8.8 atl.speedtest.clouvider.net ga-us-ping.vultr.com ash.speedtest.clouvider.net nyc.speedtest.clouvider.net iperf.he.net proof.ovh.net fsn1-speed.hetzner.com"
# iperf3 against a public server: try ports until one is free; prints "<Gb/s> port=<p> retrans=<n>"
IPF='ipf() { for p in 5201 5202 5203 5204 5205 5206 5207 5208 5209; do timeout 30 iperf3 -4 -c atl.speedtest.clouvider.net -p $p -t 10 -O 2 "$@" -J > /tmp/ipf.json 2>/dev/null
  r=$(python3 -c "import json;d=json.load(open(\"/tmp/ipf.json\"));print(\"%.2f Gb/s port=$p retrans=%s\"%(d[\"end\"][\"sum_received\"][\"bits_per_second\"]/1e9,d[\"end\"][\"sum_sent\"].get(\"retransmits\",\"-\")))" 2>/dev/null) && { echo "$r"; return; }; done; echo "no free server port"; }'
PAR='par() { local u=$1 n=$2; for i in $(seq 1 $n); do curl -s -o /dev/null -m 15 -w "%{size_download}\n" "$u" & done | awk "{s+=\$1} END {printf \"%.2f Gb/s (%d streams, %.1f GB)\", s*8/15/1e9, NR, s/1e9}"; }'

for n in $NODES; do
  say "=== node $n"
  say "  egress: $(S $n 'curl -s -m 5 https://1.1.1.1/cdn-cgi/trace | grep -E "^(ip|colo)=" | paste -sd" "')"
  for h in $PING; do say "  PING $h: $(S $n "ping -4 -q -c 50 -i 0.2 $h 2>&1 | tail -1 | sed 's/rtt min\/avg\/max\/mdev = //'")"; done
  [ $n = 864 ] && S $n 'mtr -4 -n -r -c 20 8.8.8.8; mtr -4 -n -r -c 20 1.1.1.1' > $OUT/mtr-864.txt 2>&1
  while IFS== read name u; do
    say "  DL1 $name: $(S $n "curl -s -o /dev/null -m 15 -w '%{http_code} %{size_download} %{time_total} %{speed_download}' '$u'" | awk '{printf "%.2f Gb/s (http %s, %.0f MB in %.1f s)", $4*8/1e9, $1, $2/1e6, $3}')"
  done <<< "$DL"
  say "  DL16 hetzner-ash: $(S $n "$PAR; par https://ash-speed.hetzner.com/10GB.bin 16")"
  say "  DL16 linode-atl:  $(S $n "$PAR; par https://speedtest.atlanta.linode.com/1GB-atlanta.bin 16")"
  say "  IPERF clouvider-atl down x1: $(S $n "$IPF; ipf -R")"
  say "  IPERF clouvider-atl down x8: $(S $n "$IPF; ipf -R -P 8")"
  say "  IPERF clouvider-atl up   x1: $(S $n "$IPF; ipf")"
  say "  IPERF clouvider-atl up   x8: $(S $n "$IPF; ipf -P 8")"
  say "  UP1 cloudflare: $(S $n "head -c 100000000 /dev/zero > /dev/shm/up100M; curl -s -o /dev/null -m 30 -w '%{http_code} %{size_upload} %{speed_upload}' --data-binary @/dev/shm/up100M https://speed.cloudflare.com/__up" | awk '{printf "%.2f Gb/s (http %s, %.0f MB)", $3*8/1e9, $1, $2/1e6}')"
  say "  UP8 cloudflare: $(S $n "for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -m 30 -w '%{size_upload} %{time_total}\n' --data-binary @/dev/shm/up100M https://speed.cloudflare.com/__up & done | awk '{s+=\$1; if (\$2>t) t=\$2} END {printf \"%.2f Gb/s (8 x 100 MB in %.1f s)\", s*8/t/1e9, t}'; rm -f /dev/shm/up100M")"
done

say "=== all five nodes at once"
for n in $NODES; do ( r=$(S $n "$PAR; par https://ash-speed.hetzner.com/10GB.bin 16"); say "  ALL5 DL16 hetzner-ash node $n: $r" ) & done; wait
for n in $NODES; do ( r=$(S $n "$IPF; ipf -R -P 8"); say "  ALL5 IPERF down x8 node $n: $r" ) & done; wait
say "DONE -> $OUT"

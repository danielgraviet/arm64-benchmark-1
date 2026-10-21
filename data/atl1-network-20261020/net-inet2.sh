#!/bin/bash
# Follow-up to net-inet.sh:
#   a. single-stream HTTP download per endpoint (the first pass lost these: ssh ate the loop's stdin), Cloudflare at 100 MB
#   b. per node, 4 servers at once x 8 streams (Linode ATL, Vultr ATL, Hetzner ASH, Linode Newark), 20 s:
#      separates a per-node uplink cap from one server's cap
#   c. all five nodes doing (b) at the same time: a shared site/uplink cap
set -u
OUT=/tmp/opencode/net/inet2-$(date -u +%Y%m%d_%H%M%S); mkdir -p $OUT
declare -A PUB=([853]="${NODE853_PUB:-<node853-public>}" [864]="${NODE864_PUB:-<node864-public>}" [861]="${NODE861_PUB:-<node861-public>}" [865]="${NODE865_PUB:-<node865-public>}" [857]="${NODE857_PUB:-<node857-public>}")
NODES="853 864 861 865 857"
S() { timeout ${T:-400} ssh -n -o BatchMode=yes root@${PUB[$1]} "$2"; }
say() { echo "$(date -u +%T) $*" | tee -a $OUT/summary.txt; }
DL="cloudflare-100M=https://speed.cloudflare.com/__down?bytes=100000000
linode-atl=https://speedtest.atlanta.linode.com/1GB-atlanta.bin
vultr-atl=https://ga-us-ping.vultr.com/vultr.com.1000MB.bin
hetzner-ash=https://ash-speed.hetzner.com/10GB.bin
linode-newark=https://speedtest.newark.linode.com/1GB-newark.bin
hetzner-hil=https://hil-speed.hetzner.com/10GB.bin
ovh-fr=https://proof.ovh.net/files/10Gb.dat
hetzner-fsn=https://fsn1-speed.hetzner.com/10GB.bin"
MULTI='multi() { for u in https://speedtest.atlanta.linode.com/1GB-atlanta.bin https://ga-us-ping.vultr.com/vultr.com.1000MB.bin https://ash-speed.hetzner.com/10GB.bin https://speedtest.newark.linode.com/1GB-newark.bin; do
  for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null -m 20 -w "$(echo $u | cut -d/ -f3) %{size_download}\n" "$u" & done; done | awk "{s[\$1]+=\$2; t+=\$2} END {for (h in s) printf \"%s=%.2f \", h, s[h]*8/20/1e9; printf \"| total %.2f Gb/s\", t*8/20/1e9}"; }'
for n in $NODES; do
  say "=== node $n"
  while IFS== read name u; do
    say "  DL1 $name: $(S $n "curl -s -o /dev/null -m 15 -w '%{http_code} %{size_download} %{time_total} %{speed_download}' '$u'" | awk '{printf "%.2f Gb/s (http %s, %.0f MB in %.1f s)", $4*8/1e9, $1, $2/1e6, $3}')"
  done <<< "$DL"
  say "  MULTI 4 servers x 8: $(S $n "$MULTI; multi")"
done
say "=== all five nodes at once, 4 servers x 8 streams each"
for n in $NODES; do ( r=$(S $n "$MULTI; multi"); say "  ALL5 MULTI node $n: $r" ) & done; wait
say "DONE -> $OUT"

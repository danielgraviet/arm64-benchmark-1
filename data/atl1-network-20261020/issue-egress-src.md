## What happens

On a runner host whose public IPv4 is a routed `/32` on `lo` (not the primary address of the default-route interface), **sandboxes have no internet egress at all**: DNS, ICMP, HTTP and TCP to any public address time out. The host itself reaches the internet normally.

Observed on `atl1node853` (Paperspace ATL1, a DigitalOcean company; bare-metal HPE DL325 Gen11), bench build `f0611fa13`. The code path is unchanged on `origin/main` (`b24b54026`).

## Why

The host's network layout (Paperspace netplan `/etc/netplan/99-policy-routing.yaml`):

```
lo     127.0.0.1/8 <node853-public>/32      <- public address, routed to the host
bond0  10.46.90.70/24                      <- default-route interface, private address
ip rule 500: from all lookup pub   ->  default via 10.46.90.1 dev bond0 src <node853-public>
```

The provider only routes traffic sourced from `<node853-public>` to the internet; a packet sourced from `10.46.90.70` gets no answer:

```
$ curl -s -o /dev/null -w %{http_code} https://1.1.1.1/cdn-cgi/trace                          -> 200
$ curl -s -o /dev/null -w %{http_code} --interface 10.46.90.70 https://1.1.1.1/cdn-cgi/trace  -> 000
```

The runner's egress NAT is `masquerade` on the default-route interface — `runner/internal/hostres/network.go:469` on `origin/main`:

```
ip saddr <subnet> oifname "<defaultIface()>" ct direction original masquerade
```

`masquerade` picks the primary address of `bond0` (`10.46.90.70`), ignoring the route's `src <node853-public>` hint. Capture on `bond0` while a sandbox pings `10.46.90.71` (same LAN) and then `1.1.1.1`:

```
IP 10.46.90.70 > 10.46.90.71: ICMP echo request ... / IP 10.46.90.71 > 10.46.90.70: ICMP echo reply
IP 10.46.90.70 > 1.1.1.1: ICMP echo request, seq 0     (no reply)
IP 10.46.90.70 > 1.1.1.1: ICMP echo request, seq 1     (no reply)
```

`RLP_PUBLIC_IP=<node853-public>` is set on the host, but the runner only uses it for inbound port forwards (`network.go` DNAT path), not for egress source selection.

**On `origin/main` the result is worse than on this build**: #2333 (mandatory destination-class deny) drops RFC1918 destinations for every sandbox, so the LAN path that still works here is denied too, and a sandbox on such a host can reach nothing outside the runner.

## Verified workaround (host-side, measurement only)

An `snat to <public /32>` chain at priority 99, ahead of `rlp_nat`'s masquerade at 100, restores egress:

```
table ip rlp_test_snat {
  chain post {
    type nat hook postrouting priority 99;
    ip saddr 10.140.0.0/20 oifname "bond0" ip daddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } snat to <node853-public>
  }
}
```

The same sandbox commands, before → after:

```
ping 1.1.1.1                          100% loss  ->  0.78 ms
ping <node864-public> (sibling node)    100% loss  ->  0.13 ms
wget https://1.1.1.1/cdn-cgi/trace    timeout    ->  ip=<node853-public> colo=ATL
apk add iperf3 curl                   "no such package" (index unreachable)  ->  OK
```

## Suggested fix

Choose the egress source deliberately instead of relying on `masquerade`'s interface-primary choice — e.g. when `RLP_PUBLIC_IP` (or a dedicated `RLP_EGRESS_SNAT_IP`) is set, render `snat to <ip>` instead of `masquerade`; or use the source the host's own route lookup selects (`ip route get 1.1.1.1` → `src`). The preflight could also check that a sandbox-sourced packet reaches the internet, since nothing in the current create/readiness path touches egress (the benchmark workloads never did, which is how this went unnoticed).

## Why filed separately

Found while benchmarking network performance on the Paperspace atl1 nodes; out of scope for that work.

Related: #107 (stable egress IP — would subsume this if egress gets an explicit SNAT address), #2333 / #296 (mandatory destination deny), #154 (IPv6 egress).

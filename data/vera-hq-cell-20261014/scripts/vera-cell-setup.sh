#!/bin/bash
# Single-host Daytona (rlp) benchmark cell on HQ Vera.
# Build: origin/main 33ba48051 + cherry-pick 6883d3366 (EROFS 4k blocks) + convert-system-layer -b 4096.
# Design notes (lessons from the Vera/EPYC investigation) are written to /etc/rlp/README.bench.
set -euo pipefail
B=$HOME/rlp-build; S=$B/src; O=$B/out; R=/mnt/data/rlp
PUBIP=10.96.8.228
say() { echo "[$(date -u +%T)] $*"; }

# ---------- binaries ----------
sudo install -m 755 $B/bin/rlp-runner $B/bin/rlp-proxy $B/bin/rlp-egressd $O/firecracker /usr/local/bin/
sudo install -m 755 $B/bin/rlp-fcns /usr/local/bin/rlp-fcns && sudo setcap cap_sys_admin+ep /usr/local/bin/rlp-fcns
sudo mkdir -p /opt/rlp && sudo install -m 755 $O/rlp-api /opt/rlp/rlp-api && sudo ln -sf /opt/rlp/rlp-api /usr/local/bin/rlp-api
sudo install -m 755 $S/deploy/rlp-cgroup-setup /usr/local/bin/rlp-cgroup-setup
sudo install -m 644 $O/kernel/initdisk-rlp.ext4 /var/lib/rlp/initdisk-rlp.ext4
echo "daytona f0611fa13 + cherry-pick 6883d3366 (EROFS -b 4096) + convert-system-layer -b 4096; built $(date -u +%F) on vera; same Daytona build as the epyc9755 cell" | sudo tee /etc/rlp/BUILD >/dev/null
say "binaries installed: $(ls /usr/local/bin | grep -E '^rlp-|firecracker' | tr '\n' ' ')"

# ---------- secrets (root-only) ----------
sudo mkdir -p /etc/rlp && sudo chmod 750 /etc/rlp
gen() { openssl rand -hex 24; }
[ -f /etc/rlp/.secrets ] || { printf 'NATS_TOKEN=%s\nPG_PW=%s\nINTERNAL_TOKEN=%s\n' "$(gen)" "$(gen)" "$(gen)" | sudo tee /etc/rlp/.secrets >/dev/null; sudo chmod 600 /etc/rlp/.secrets; }
eval "$(sudo cat /etc/rlp/.secrets)"

# ---------- postgres + nats (host network, localhost only) ----------
printf 'listen: 127.0.0.1:4222\nhttp: 127.0.0.1:8222\nauthorization { token: "%s" }\njetstream { store_dir: /data\n max_memory_store: 8G\n max_file_store: 200G }\nmax_payload: 8MB\n' "$NATS_TOKEN" | sudo tee /etc/rlp/nats.conf >/dev/null; sudo chmod 640 /etc/rlp/nats.conf
sudo docker rm -f rlp-postgres rlp-nats >/dev/null 2>&1 || true
sudo docker run -d --name rlp-postgres --restart unless-stopped --network host \
  -e POSTGRES_USER=rlp -e POSTGRES_PASSWORD="$PG_PW" -e POSTGRES_DB=rlplatform \
  -v $R/pg:/var/lib/postgresql/data postgres:16 \
  -c listen_addresses=127.0.0.1 -c port=5439 -c max_connections=800 -c shared_buffers=8GB -c synchronous_commit=off -c wal_level=logical >/dev/null
sudo docker run -d --name rlp-nats --restart unless-stopped --network host \
  -v $R/nats:/data -v /etc/rlp/nats.conf:/etc/nats.conf:ro nats:2.10 -c /etc/nats.conf >/dev/null
for i in $(seq 1 60); do sudo docker exec rlp-postgres pg_isready -h 127.0.0.1 -p 5439 -U rlp >/dev/null 2>&1 && break; sleep 2; done
for i in $(seq 1 30); do curl -fsS -m2 127.0.0.1:8222/healthz >/dev/null 2>&1 && break; sleep 1; done
say "postgres: $(sudo docker exec rlp-postgres pg_isready -h 127.0.0.1 -p 5439 -U rlp | grep -o 'accepting.*')  nats: $(curl -s 127.0.0.1:8222/healthz)"
( cd $S/deploy && sudo NATS_URL=nats://127.0.0.1:4222 NATS_TOKEN="$NATS_TOKEN" RLP_NATS_PROVISION_PASSWORD="" RLP_NATS_CONTAINER=rlp-nats bash provision-nats.sh ) > $B/logs/provision-nats.log 2>&1 \
  && say "nats streams: $(grep -cE '^\[\*\]' $B/logs/provision-nats.log) provisioning steps ok" || { say "provision-nats FAILED"; tail -5 $B/logs/provision-nats.log; exit 1; }

# ---------- region seed ----------
cat <<'J' | sudo tee /etc/rlp/regions.json >/dev/null
{"macro_regions":[{"id":"vera-cell","cell_id":"vera-cell","name":"HQ Vera bench cell","global_region_id":"us"}],
 "regions":[{"id":"vera","name":"HQ Vera","macro_region_id":"vera-cell","is_default":true,"status":"active",
   "auto_placement_enabled":true,"default_cpu_arch":"arm64","default_network_class":"standard","default_disk_class":"standard",
   "toolbox_proxy_url":"http://127.0.0.1:9000/toolbox"}]}
J

# ---------- api ----------
sudo tee /etc/rlp/api.env >/dev/null <<E
DATABASE_URL=postgres://rlp:$PG_PW@127.0.0.1:5439/rlplatform
NATS_URL=nats://127.0.0.1:4222
NATS_TOKEN=$NATS_TOKEN
API_BIND=127.0.0.1:8088
RLP_REGIONS_SEED=/etc/rlp/regions.json
RLP_ALLOW_NON_NVMEOF_RUNNERS=1
RLP_INTERNAL_TOKEN=$INTERNAL_TOKEN
RLP_TOOLBOX_PROXY_URL=http://127.0.0.1:9000/toolbox
# sandbox shape bounds needed by the published benchmark (0.025 CPU / 64 MiB / 4 GiB burst / small disks)
RLP_MIN_CPU=0.025
RLP_MIN_MEM_MIB=64
RLP_MIN_SCRATCH_MIB=16
RLP_MEM_MIB_PER_CPU=8192
RLP_BURST_MAX_CPU=1
RLP_BURST_MAX_MEM_MIB=4096
RLP_IDLE_REAP_ENABLED=1
RLP_OTEL_DISABLED=1
# Required by the global-artifact-store startup guard (G4). Name only: the API holds no S3 client and the
# runner has no RLP_ARTIFACT_S3_* credentials, so nothing is exported. Single-region cell, always warm.
RLP_ARTIFACT_S3_BUCKET=rlp-artifacts-unused
# NOTE: event auditing left at the platform default (on). Vera's old tuning package turned it off;
# on the 9575F that made no measurable difference. Change only as an explicit, recorded A/B.
E
sudo chmod 600 /etc/rlp/api.env
sudo install -m 644 $S/deploy/rlp-api.service /etc/systemd/system/rlp-api.service
sudo mkdir -p /etc/systemd/system/rlp-api.service.d
printf '[Service]\nUser=root\n' | sudo tee /etc/systemd/system/rlp-api.service.d/10-bench.conf >/dev/null

# ---------- runner ----------
sudo tee /etc/rlp/runner.env >/dev/null <<E
RLP_NATS_URL=nats://127.0.0.1:4222
RLP_NATS_TOKEN=$NATS_TOKEN
RLP_RUNNER_ID=vera-1
RLP_RUNNER_REGION=vera
RLP_PUBLIC_IP=$PUBIP
RLP_SUBNET_CIDR=10.101.32.0/20
RLP_GUEST_ARCH=arm64
RLP_NFS_ROOT=$R
RLP_LAYERS_MOUNT=$R/layers
RLP_CAS_DIR=$R/layers/sha256
RLP_MANIFESTS_DIR=$R/manifests
RLP_SYSTEM_DIR=$R/system
RLP_TEMPLATE_CAS_DIR=$R/templates
RLP_LOCAL_SCRATCH=$R/scratch
RLP_KERNEL=$R/kernel/Image-6.12.34-rlp1-arm64
RLP_INITDISK=/var/lib/rlp/initdisk-rlp.ext4
RLP_FC_BIN=/usr/local/bin/firecracker
RLP_SNAPSHOTS=1
RLP_NETNS_NETLINK=1
RLP_NETNS_POOL=2100
RLP_VM_CONCURRENCY=512
RLP_MAX_LIVE_VMS=3000
RLP_RESERVE_PCT=95
RLP_MEM_MIB_PER_CPU=8192
RLP_TOOLBOX_WAIT_SEC=300
# 64 KiB host pages: the Firecracker balloon corrupts guest memory (#1066). Must stay off.
RLP_BALLOON=0
RLP_KSM=0
RLP_BUILDER_IMAGE=off
RLP_BLOCKMOUNT_ENABLED=0
RLP_USAGE_SHIP_INTERVAL=0
RLP_OTEL_DISABLED=1
E
sudo chmod 600 /etc/rlp/runner.env
sudo install -m 644 $S/deploy/rlp.slice /etc/systemd/system/rlp.slice
sudo install -m 644 $S/deploy/rlp-runner.service /etc/systemd/system/rlp-runner.service

# ---------- start api, bootstrap tenant, mint key ----------
sudo systemctl daemon-reload
sudo systemctl enable --now rlp-api >/dev/null 2>&1
for i in $(seq 1 60); do curl -fsS -m2 127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 2; done
say "api health: $(curl -s -o /dev/null -w '%{http_code}' 127.0.0.1:8088/health)"
PG() { sudo docker exec -i rlp-postgres psql -h 127.0.0.1 -p 5439 -U rlp -d rlplatform -tAc "$1"; }
PROJECT_ID=$(PG "INSERT INTO organizations (name) SELECT 'bootstrap' WHERE NOT EXISTS (SELECT 1 FROM organizations WHERE name='bootstrap');
  INSERT INTO projects (org_id,name) SELECT o.id,'default' FROM organizations o WHERE o.name='bootstrap' ON CONFLICT (org_id,name) DO NOTHING;
  SELECT p.id FROM projects p JOIN organizations o ON o.id=p.org_id WHERE o.name='bootstrap' AND p.name='default' LIMIT 1;" | tail -1 | tr -d '[:space:]')
KEY=$(sudo bash -c "set -a; . /etc/rlp/api.env; set +a; /opt/rlp/rlp-api mint-key bench --project $PROJECT_ID --project-permissions all" 2>/dev/null | grep -oE 'dtn_[A-Za-z0-9]+' | head -1)
[ -n "$KEY" ] || { say "mint-key FAILED"; exit 1; }
echo "$KEY" | sudo tee /etc/rlp/bench-api-key >/dev/null; sudo chmod 600 /etc/rlp/bench-api-key
say "project=$PROJECT_ID key=${KEY:0:8}..."

# ---------- proxy ----------
sudo tee /etc/rlp/proxy.env >/dev/null <<E
RLP_DB_URL=postgres://rlp:$PG_PW@127.0.0.1:5439/rlplatform
RLP_NATS_URL=nats://127.0.0.1:4222
RLP_NATS_TOKEN=$NATS_TOKEN
RLP_INTERNAL_TOKEN=$INTERNAL_TOKEN
RLP_API_URL=http://127.0.0.1:8088
RLP_API_KEY=$KEY
RLP_PROXY_LISTEN=0.0.0.0:9000
RLP_SSH_LISTEN=127.0.0.1:2222
RLP_SSH_HOST_KEY_PATH=/etc/rlp/ssh_host_key
RLP_REGION=vera
RLP_OTEL_DISABLED=1
E
sudo chmod 600 /etc/rlp/proxy.env
# single host: no WireGuard overlay -> drop the wg-quick@wg0 dependency from the unit
sed -e 's/ wg-quick@wg0.service//' -e '/^Requires=wg-quick@wg0.service$/d' $S/deploy/rlp-proxy.service | sudo tee /etc/systemd/system/rlp-proxy.service >/dev/null
sudo rm -rf /etc/systemd/system/rlp-proxy.service.d
sudo systemctl daemon-reload
sudo systemctl enable --now rlp-proxy rlp-runner >/dev/null 2>&1
sleep 25
say "services: api=$(systemctl is-active rlp-api) proxy=$(systemctl is-active rlp-proxy) runner=$(systemctl is-active rlp-runner)"
say "runners: $(PG "select string_agg(id||' '||status, ', ') from runners")"
say "netns pool: $(sudo ip netns list | wc -l)"

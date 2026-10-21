set -u
PG() { docker exec -i rlp-postgres psql -U rlp -d rlplatform -v ON_ERROR_STOP=1 -tAc "$1"; }
PG "insert into macro_regions (id, name, cell_id, global_region_id) values ('atl1-cell','ATL EPYC 9555P cell','atl1','us') on conflict (id) do nothing"
PG "update regions set macro_region_id='atl1-cell' where id='atl1' and macro_region_id is null"
echo "regions: $(PG "select id||'->'||macro_region_id from regions")"
cp -a /etc/rlp/regions.json /etc/rlp/regions.json.bak-sep15
cat > /etc/rlp/regions.json <<'J'
{
  "macro_regions": [
    { "id": "atl1-cell", "cell_id": "atl1", "name": "ATL EPYC 9555P cell", "global_region_id": "us" }
  ],
  "regions": [
    { "id": "atl1", "name": "ATL EPYC 9555P", "status": "active", "is_default": true, "macro_region_id": "atl1-cell",
      "auto_placement_enabled": true, "default_cpu_arch": "amd64", "default_network_class": "standard",
      "default_disk_class": "standard", "toolbox_proxy_url": "http://127.0.0.1:9000/toolbox" }
  ]
}
J
echo "$(date -u +%FT%TZ) region hierarchy for the f0611fa13 schema: macro_regions atl1-cell (cell atl1, global us), regions.atl1.macro_region_id=atl1-cell; /etc/rlp/regions.json rewritten in the 9575F's format (old kept .bak-sep15)" >> /etc/rlp/HOSTCHANGES
systemctl restart rlp-api
for i in $(seq 1 180); do curl -fsS -m 2 http://127.0.0.1:8088/health >/dev/null 2>&1 && break; sleep 1; done
echo "api health $(curl -s -m 3 -o /dev/null -w %{http_code} http://127.0.0.1:8088/health) migrations $(PG "select max(version)||' '||count(*) from _sqlx_migrations")"
journalctl -u rlp-api --since -3min --no-pager -o cat | grep -iE "error|backlog|seed" | tail -4 | cut -c1-200
systemctl restart rlp-runner; sleep 5
ok=0; for i in $(seq 1 120); do n=$(ip netns list | wc -l); if [ $n -ge 1995 ]; then ok=$((ok+1)); [ $ok -ge 2 ] && break; else ok=0; fi; sleep 10; done
echo "runner=$(systemctl is-active rlp-runner) netns=$(ip netns list | wc -l) backlog=$(ss -ltn 'sport = :8088' | awk 'NR==2{print $2+$3}') runner_status=$(PG "select status||' '||coalesce(admin_state,'') from runners where id='atl1-node853'")"
bench-preflight /tmp/pf-deploy2 2>/dev/null | grep -E "FAIL|create_path_fixes|PREFLIGHT"

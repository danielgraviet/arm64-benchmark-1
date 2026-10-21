set -u
k=$(cat /etc/rlp/bench-api-key); h=$(printf '%s' "$k" | sha256sum | cut -d' ' -f1)
PG() { docker exec -i rlp-postgres psql -U rlp -d rlplatform -tAc "$1"; }
P=$(PG "select project_id from project_api_keys where token_hash='$h'")
PERMS=$(PG "select array_to_string(permissions, ',') from project_api_keys where token_hash='$h'")
echo "project=$P perms_count=$(echo $PERMS | tr ',' '\n' | wc -l)"
set -a; . /etc/rlp/api.env; set +a
OUT=$(/usr/local/bin/rlp-api mint-key bench-20261020 --project "$P" --project-permissions "$PERMS" 2>&1)
T=$(echo "$OUT" | grep -oE '\bdtn1?_[A-Za-z0-9_]+' | head -1)
[ -n "$T" ] || { echo "mint failed: $(echo "$OUT" | tail -3)"; exit 1; }
echo "minted prefix=${T:0:8} len=${#T} GET /vms -> $(curl -s -o /dev/null -w %{http_code} -H "Authorization: Bearer $T" http://127.0.0.1:8088/vms?limit=1)"
cp -a /etc/rlp/bench-api-key /etc/rlp/bench-api-key.legacy-rlp; printf '%s' "$T" > /etc/rlp/bench-api-key; chmod 600 /etc/rlp/bench-api-key
sed -i "s|^RLP_API_KEY=.*|RLP_API_KEY=$T|" /home/ubuntu/arm64-benchmark-1/.env
echo "$(date -u +%FT%TZ) minted current-format project key 'bench-20261020' (rlp-api mint-key, same project + permissions as the legacy rlp_ key, which the f0611fa13 API rejects); /etc/rlp/bench-api-key + harness .env updated, legacy key kept in bench-api-key.legacy-rlp" >> /etc/rlp/HOSTCHANGES

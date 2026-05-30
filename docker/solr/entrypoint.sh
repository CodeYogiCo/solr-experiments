#!/bin/bash
# Solr entrypoint — single node with ZooKeeper embedded inside the Solr process
# (-DzkRun). Local playground only; no external ZooKeeper.
set -euo pipefail

SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_HEAP="${SOLR_HEAP:-1g}"
NODE_NAME="${HOSTNAME}"

echo ">>> Starting Solr in EMBEDDED mode (ZooKeeper inside the Solr process)"
echo ">>> Solr port: ${SOLR_PORT}   Embedded ZK port: 9983"

# Start Solr with embedded ZK (-DzkRun). The Redis connection is passed as
# system properties so the plugin's ${redis.host}/${redis.port} placeholders
# resolve from the container env.
/opt/solr/bin/solr start \
  -cloud \
  -DzkRun \
  -p "${SOLR_PORT}" \
  -m "${SOLR_HEAP}" \
  -Dsolr.node.name="${NODE_NAME}" \
  -Dredis.host="${REDIS_HOST:-redis}" \
  -Dredis.port="${REDIS_PORT:-6379}"

echo ">>> Waiting for embedded Solr to be ready..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${SOLR_PORT}/solr/admin/info/system" > /dev/null 2>&1; then
    echo ">>> Solr is ready."
    break
  fi
  [ "${i}" -eq 30 ] && echo "ERROR: Solr did not start in time" && exit 1
  sleep 3
done

# Upload the bestbuy configset to the embedded ZooKeeper.
echo ">>> Uploading bestbuy configset to ZooKeeper..."
/opt/solr/bin/solr zk upconfig \
  -n bestbuy \
  -d /opt/solr/server/solr/configsets/bestbuy/conf \
  -z "localhost:9983" 2>/dev/null || true

# Optionally create the bestbuy collection on first start (idempotent).
if [ "${AUTO_CREATE_COLLECTION:-false}" = "true" ]; then
  if curl -sf "http://localhost:${SOLR_PORT}/solr/admin/collections?action=LIST" \
       | grep -q '"bestbuy"'; then
    echo ">>> Collection 'bestbuy' already exists."
  else
    echo ">>> Creating 'bestbuy' collection (1 shard, RF 1)..."
    curl -sf "http://localhost:${SOLR_PORT}/solr/admin/collections?action=CREATE&name=bestbuy&numShards=1&replicationFactor=1&collection.configName=bestbuy" \
      > /dev/null && echo ">>> Collection 'bestbuy' created." \
      || echo ">>> WARNING: collection create failed; create it manually with 'make collection'."
  fi
fi

echo ">>> Solr UI: http://localhost:${SOLR_PORT}/solr"

# solr start is non-blocking; tail the log to keep the container alive.
# -F (not -f) retries if the file is rotated or not yet created.
exec tail -F /var/solr/logs/solr.log

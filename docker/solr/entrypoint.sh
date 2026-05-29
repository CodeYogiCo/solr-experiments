#!/bin/bash
# Solr SolrCloud entrypoint.
#
# ZooKeeper address resolution (in order):
#   1. ZK_HOST env var set explicitly          → use it as-is
#   2. ZK_HOST not set                         → default to "zookeeper-lb:2181"
#      which resolves to the HAProxy / cloud LB / Docker DNS alias
#
# The ZK load balancer handles health-checking the ensemble and routing
# to live nodes. Solr doesn't need to know individual ZK addresses.
set -euo pipefail

SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_HEAP="${SOLR_HEAP:-2g}"
NODE_NAME="${HOSTNAME}"
ZK_WAIT_RETRIES="${ZK_WAIT_RETRIES:-30}"
ZK_WAIT_INTERVAL="${ZK_WAIT_INTERVAL:-5}"

# ── Step 1: resolve ZK address ────────────────────────────────────────────────
ZK_HOST="${ZK_HOST:-zookeeper-lb:2181}"
echo ">>> ZooKeeper address: ${ZK_HOST}"

# ── Step 2: wait until ZK is reachable ────────────────────────────────────────
ZK_HOST_ONLY="${ZK_HOST%%:*}"
ZK_PORT_ONLY="${ZK_HOST##*:}"

echo ">>> Waiting for ZooKeeper at ${ZK_HOST}..."
for attempt in $(seq 1 "${ZK_WAIT_RETRIES}"); do
  if echo ruok | nc -w 2 "${ZK_HOST_ONLY}" "${ZK_PORT_ONLY}" 2>/dev/null | grep -q imok; then
    echo ">>> ZooKeeper is ready (attempt ${attempt})"
    break
  fi
  if [ "${attempt}" -eq "${ZK_WAIT_RETRIES}" ]; then
    echo "ERROR: ZooKeeper not reachable at ${ZK_HOST} after ${ZK_WAIT_RETRIES} attempts."
    exit 1
  fi
  echo ">>> ZooKeeper not ready yet (attempt ${attempt}/${ZK_WAIT_RETRIES}), retrying in ${ZK_WAIT_INTERVAL}s..."
  sleep "${ZK_WAIT_INTERVAL}"
done

# ── Step 3: upload configset (idempotent – safe to run on every node start) ───
echo ">>> Uploading bestbuy configset to ZooKeeper..."
/opt/solr/bin/solr zk upconfig \
  -n bestbuy \
  -d /opt/solr/server/solr/configsets/bestbuy/conf \
  -z "${ZK_HOST}" 2>/dev/null || true

# ── Step 4: start Solr ────────────────────────────────────────────────────────
echo ">>> Starting Solr node ${NODE_NAME} → ZK: ${ZK_HOST}"
exec /opt/solr/bin/solr start \
  -f \
  -cloud \
  -z "${ZK_HOST}" \
  -p "${SOLR_PORT}" \
  -m "${SOLR_HEAP}" \
  -Dsolr.node.name="${NODE_NAME}" \
  -Dsolr.jetty.request.header.size=65536

#!/bin/bash
# Solr SolrCloud entrypoint.
# Discovers ZooKeeper automatically, then starts Solr and uploads the configset.
set -euo pipefail

SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_HEAP="${SOLR_HEAP:-2g}"
NODE_NAME="${HOSTNAME}"
ZK_DISCOVERY_RETRIES="${ZK_DISCOVERY_RETRIES:-20}"   # how many times to retry before giving up
ZK_DISCOVERY_INTERVAL="${ZK_DISCOVERY_INTERVAL:-10}" # seconds between retries

# ── Step 1: discover ZooKeeper ────────────────────────────────────────────────
echo ">>> Discovering ZooKeeper ensemble..."

ZK_HOST=""
for attempt in $(seq 1 "$ZK_DISCOVERY_RETRIES"); do
  ZK_HOST=$(bash /discover-zk.sh 2>/dev/null || true)

  if [ -n "$ZK_HOST" ]; then
    echo ">>> ZooKeeper found on attempt ${attempt}: ${ZK_HOST}"
    break
  fi

  echo ">>> ZooKeeper not yet available (attempt ${attempt}/${ZK_DISCOVERY_RETRIES})," \
       "retrying in ${ZK_DISCOVERY_INTERVAL}s..."
  sleep "$ZK_DISCOVERY_INTERVAL"
done

if [ -z "$ZK_HOST" ]; then
  echo "ERROR: Could not discover ZooKeeper after ${ZK_DISCOVERY_RETRIES} attempts."
  echo "       See /discover-zk.sh for which discovery methods were tried."
  exit 1
fi

export ZK_HOST

# ── Step 2: upload configset (idempotent – safe to run on every node start) ───
echo ">>> Uploading bestbuy configset to ZooKeeper..."
/opt/solr/bin/solr zk upconfig \
  -n bestbuy \
  -d /opt/solr/server/solr/configsets/bestbuy/conf \
  -z "${ZK_HOST}" 2>/dev/null || true
# 'true' because another node racing here causes a harmless "already exists" error

# ── Step 3: start Solr ────────────────────────────────────────────────────────
echo ">>> Starting Solr node ${NODE_NAME} connected to ZK: ${ZK_HOST}"

exec /opt/solr/bin/solr start \
  -f \
  -cloud \
  -z "${ZK_HOST}" \
  -p "${SOLR_PORT}" \
  -m "${SOLR_HEAP}" \
  -Dsolr.node.name="${NODE_NAME}" \
  -Dsolr.jetty.request.header.size=65536

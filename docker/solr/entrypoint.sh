#!/bin/bash
# Solr entrypoint – two modes controlled by SOLR_MODE env var:
#
#   SOLR_MODE=embedded    Single node, ZooKeeper runs inside this Solr process.
#                         No external ZK needed. Good for dev / experimentation.
#
#   SOLR_MODE=production  (default) External ZooKeeper cluster.
#                         Waits for ZK_HOST to be reachable, then starts Solr
#                         in SolrCloud mode connected to the ZK load balancer.
set -euo pipefail

SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_HEAP="${SOLR_HEAP:-2g}"
NODE_NAME="${HOSTNAME}"
SOLR_MODE="${SOLR_MODE:-production}"

upload_configset() {
  local zk_addr="$1"
  echo ">>> Uploading bestbuy configset to ZooKeeper at ${zk_addr}..."
  /opt/solr/bin/solr zk upconfig \
    -n bestbuy \
    -d /opt/solr/server/solr/configsets/bestbuy/conf \
    -z "${zk_addr}" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════
#  EMBEDDED MODE  –  ZooKeeper runs inside this Solr process
# ════════════════════════════════════════════════════════════════════════════
if [ "${SOLR_MODE}" = "embedded" ]; then
  echo ">>> Starting in EMBEDDED mode (ZooKeeper inside Solr process)"
  echo ">>> Solr port: ${SOLR_PORT}   Embedded ZK port: 9983"

  # Start Solr with embedded ZK (-DzkRun) and wait for it to be ready
  /opt/solr/bin/solr start \
    -cloud \
    -DzkRun \
    -p "${SOLR_PORT}" \
    -m "${SOLR_HEAP}" \
    -Dsolr.node.name="${NODE_NAME}"

  # Wait until the embedded Solr + ZK are up
  echo ">>> Waiting for embedded Solr to be ready..."
  for i in $(seq 1 30); do
    if curl -sf "http://localhost:${SOLR_PORT}/solr/admin/info/system" > /dev/null 2>&1; then
      echo ">>> Solr is ready."
      break
    fi
    [ "${i}" -eq 30 ] && echo "ERROR: Solr did not start in time" && exit 1
    sleep 3
  done

  # Upload configset to the embedded ZK
  upload_configset "localhost:9983"

  echo ">>> Embedded SolrCloud is up."
  echo ">>> Solr UI:         http://localhost:${SOLR_PORT}/solr"
  echo ">>> Embedded ZK:     localhost:9983"
  echo ""
  echo ">>> To create the bestbuy collection:"
  echo ">>>   curl 'http://localhost:${SOLR_PORT}/solr/admin/collections"
  echo ">>>     ?action=CREATE&name=bestbuy&numShards=1&replicationFactor=1"
  echo ">>>     &collection.configName=bestbuy'"

  # Keep the process alive (solr start is non-blocking, tail keeps container running)
  exec tail -f /var/solr/logs/solr.log

# ════════════════════════════════════════════════════════════════════════════
#  PRODUCTION MODE  –  External ZooKeeper cluster via load balancer
# ════════════════════════════════════════════════════════════════════════════
else
  ZK_HOST="${ZK_HOST:-zookeeper-lb:2181}"
  ZK_WAIT_RETRIES="${ZK_WAIT_RETRIES:-30}"
  ZK_WAIT_INTERVAL="${ZK_WAIT_INTERVAL:-5}"

  ZK_HOST_ONLY="${ZK_HOST%%:*}"
  ZK_PORT_ONLY="${ZK_HOST##*:}"

  echo ">>> Starting in PRODUCTION mode"
  echo ">>> ZooKeeper LB address: ${ZK_HOST}"

  # Wait until the ZK load balancer is reachable
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
    echo ">>> Not ready yet (${attempt}/${ZK_WAIT_RETRIES}), retrying in ${ZK_WAIT_INTERVAL}s..."
    sleep "${ZK_WAIT_INTERVAL}"
  done

  upload_configset "${ZK_HOST}"

  echo ">>> Starting Solr node ${NODE_NAME} → ZK: ${ZK_HOST}"
  exec /opt/solr/bin/solr start \
    -f \
    -cloud \
    -z "${ZK_HOST}" \
    -p "${SOLR_PORT}" \
    -m "${SOLR_HEAP}" \
    -Dsolr.node.name="${NODE_NAME}" \
    -Dsolr.jetty.request.header.size=65536
fi

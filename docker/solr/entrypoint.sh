#!/bin/bash
set -euo pipefail

ZK_HOST="${ZK_HOST:-zookeeper1:2181,zookeeper2:2181,zookeeper3:2181}"
SOLR_PORT="${SOLR_PORT:-8983}"
SOLR_HEAP="${SOLR_HEAP:-2g}"
NODE_NAME="${HOSTNAME}"

wait_for_zookeeper() {
  local host port
  IFS=',' read -ra NODES <<< "${ZK_HOST}"
  for node in "${NODES[@]}"; do
    host="${node%%:*}"
    port="${node##*:}"
    echo "Waiting for ZooKeeper at ${host}:${port}..."
    until nc -z "${host}" "${port}"; do
      sleep 2
    done
    echo "ZooKeeper ${host}:${port} is ready."
    return 0
  done
}

upload_configset() {
  local collection="bestbuy"
  local configset_path="/opt/solr/server/solr/configsets/bestbuy/conf"

  echo "Uploading configset '${collection}' to ZooKeeper..."
  /opt/solr/bin/solr zk upconfig \
    -n "${collection}" \
    -d "${configset_path}" \
    -z "${ZK_HOST}" || true
}

wait_for_zookeeper
upload_configset

exec /opt/solr/bin/solr start \
  -f \
  -cloud \
  -z "${ZK_HOST}" \
  -p "${SOLR_PORT}" \
  -m "${SOLR_HEAP}" \
  -Dsolr.node.name="${NODE_NAME}" \
  -Dsolr.jetty.request.header.size=65536

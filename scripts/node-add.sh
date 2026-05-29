#!/bin/bash
# Add a Solr node to the running cluster.
# Usage: ./scripts/node-add.sh <NODE_NUMBER>
# Example: ./scripts/node-add.sh 3   → starts solr-node-3
#
# The node registers itself with ZooKeeper automatically on startup.
# ZooKeeper then makes it available for shard assignment.
set -euo pipefail

NODE="${1:?Usage: $0 <node-number>}"
PROFILE="solr-node-${NODE}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"

echo "Adding Solr node ${NODE} (profile: ${PROFILE})..."

# Verify the profile exists in the compose file
if ! grep -q "profiles:.*${PROFILE}" "${COMPOSE_FILE}"; then
  echo ""
  echo "ERROR: Profile '${PROFILE}' not found in ${COMPOSE_FILE}."
  echo "To add node ${NODE}, append this block to the 'services' section"
  echo "of ${COMPOSE_FILE}:"
  echo ""
  echo "  solr-node-${NODE}:"
  echo "    <<: *solr"
  echo "    profiles: [\"solr-node-${NODE}\"]"
  echo "    hostname: solr-node-${NODE}"
  # suggest next unused port
  LAST_PORT=$(grep -E '^\s+- "\d+:8983"' "${COMPOSE_FILE}" | \
              grep -oE '[0-9]+:8983' | sort -t: -k1 -n | tail -1 | cut -d: -f1)
  NEXT_PORT=$((${LAST_PORT:-8982} + 1))
  echo "    ports: [\"${NEXT_PORT}:8983\"]"
  echo "    volumes: [solr-node-${NODE}-data:/var/solr/data]"
  echo ""
  echo "Also add 'solr-node-${NODE}-data:' under the 'volumes' section."
  exit 1
fi

# Start the node
docker compose -f "${COMPOSE_FILE}" --profile "${PROFILE}" up -d

# Wait for it to come up
echo "Waiting for solr-node-${NODE} to be ready..."
TIMEOUT=120
ELAPSED=0
until docker compose -f "${COMPOSE_FILE}" \
        --profile "${PROFILE}" \
        exec "solr-node-${NODE}" \
        curl -sf http://localhost:8983/solr/admin/info/system > /dev/null 2>&1; do
  sleep 5
  ELAPSED=$((ELAPSED + 5))
  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "Timed out waiting for solr-node-${NODE}"
    exit 1
  fi
done

echo ""
echo "solr-node-${NODE} is up and registered with ZooKeeper."
echo "Cluster nodes (live_nodes in ZK):"
curl -sf "http://localhost:8983/solr/admin/collections?action=CLUSTERSTATUS" \
  | python3 -c "
import json, sys
cs = json.load(sys.stdin)
for n in sorted(cs.get('cluster', {}).get('live_nodes', [])):
    print('  ✓', n)
" 2>/dev/null || echo "  (install python3 for cluster status display)"

#!/bin/bash
# Gracefully remove a Solr node from the cluster.
# Usage: ./scripts/node-remove.sh <NODE_NUMBER> [--force]
#
# What this does:
#   1. Checks that enough other nodes are alive (warns if replicas are at risk)
#   2. Signals Solr to hand off any shard leadership it holds
#   3. Stops and removes the container (ZooKeeper detects the departure in <5s
#      and elects a new leader for any shards that lost theirs)
#   4. Removes the node from ZooKeeper's /live_nodes ephemeral znode
#      (this happens automatically when the container stops)
#
# Note: the volume (persistent data) is NOT deleted. Run with --purge to also
# remove the volume (only do this when permanently decommissioning the node).
set -euo pipefail

NODE="${1:?Usage: $0 <node-number> [--force] [--purge]}"
PROFILE="solr-node-${NODE}"
SOLR_URL="${SOLR_URL:-http://localhost:8983/solr}"
FORCE=false
PURGE=false

for arg in "$@"; do
  [ "$arg" = "--force" ] && FORCE=true
  [ "$arg" = "--purge" ] && PURGE=true
done

container_running() {
  docker compose --profile "${PROFILE}" ps --status running "solr-node-${NODE}" \
    2>/dev/null | grep -q "solr-node-${NODE}"
}

if ! container_running; then
  echo "solr-node-${NODE} is not running."
  exit 0
fi

# ── Safety check: count live nodes ───────────────────────────────────────────
LIVE_NODE_COUNT=$(curl -sf \
  "${SOLR_URL}/admin/collections?action=CLUSTERSTATUS" 2>/dev/null \
  | python3 -c "
import json, sys
cs = json.load(sys.stdin)
print(len(cs.get('cluster', {}).get('live_nodes', [])))
" 2>/dev/null || echo "0")

if [ "${LIVE_NODE_COUNT}" -le 1 ] && [ "${FORCE}" = false ]; then
  echo "ERROR: This is the last live Solr node. Removing it will take the"
  echo "cluster offline. Use --force if you really want to do this."
  exit 1
fi

if [ "${LIVE_NODE_COUNT}" -le 2 ] && [ "${FORCE}" = false ]; then
  echo "WARNING: Only ${LIVE_NODE_COUNT} nodes are live. After removal,"
  echo "any shard with replication factor 2 will have no replicas."
  echo "Re-run with --force to proceed anyway."
  exit 1
fi

echo "Removing solr-node-${NODE} from cluster (${LIVE_NODE_COUNT} nodes currently live)..."

# ── Step 1: Resign any active leader role via Solr API ────────────────────────
# This is a best-effort call – it triggers replica election before we stop.
NODE_HOST="solr-node-${NODE}:8983_solr"
echo "Requesting leader step-down for node ${NODE_HOST}..."
curl -sf "${SOLR_URL}/admin/cores?action=REQUESTRECOVERY&core=${NODE_HOST}" \
  > /dev/null 2>&1 || true

sleep 3   # give ZK time to elect replacements

# ── Step 2: Stop + remove container ──────────────────────────────────────────
echo "Stopping container..."
docker compose --profile "${PROFILE}" stop "solr-node-${NODE}"
docker compose --profile "${PROFILE}" rm -f "solr-node-${NODE}"

# ZooKeeper removes the ephemeral /live_nodes entry automatically when
# the Solr process disconnects. No manual ZK cleanup needed.

echo "solr-node-${NODE} removed. ZooKeeper will elect new shard leaders"
echo "for any shards that were led by this node within ~5 seconds."

# ── Step 3: Optionally purge the data volume ──────────────────────────────────
if [ "${PURGE}" = true ]; then
  VOLUME_NAME="$(basename "$(pwd)")_solr-node-${NODE}-data"
  echo "Purging volume ${VOLUME_NAME}..."
  docker volume rm "${VOLUME_NAME}" 2>/dev/null || \
    echo "Volume not found (may have already been removed)."
fi

# ── Status after removal ──────────────────────────────────────────────────────
echo ""
echo "Remaining live nodes:"
curl -sf "${SOLR_URL}/admin/collections?action=CLUSTERSTATUS" \
  | python3 -c "
import json, sys
cs = json.load(sys.stdin)
for n in sorted(cs.get('cluster', {}).get('live_nodes', [])):
    print('  ✓', n)
" 2>/dev/null || echo "  (check Solr admin UI for cluster status)"

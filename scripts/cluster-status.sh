#!/bin/bash
# Print a human-readable view of the SolrCloud cluster state.
# Usage: ./scripts/cluster-status.sh [SOLR_URL]
set -euo pipefail

SOLR_URL="${1:-http://localhost:8983/solr}"

echo "═══════════════════════════════════════════════════════"
echo "  SolrCloud Cluster Status"
echo "═══════════════════════════════════════════════════════"

# ── Live nodes ────────────────────────────────────────────────────────────────
echo ""
echo "Live nodes (registered in ZooKeeper /live_nodes):"
curl -sf "${SOLR_URL}/admin/collections?action=CLUSTERSTATUS" \
  | python3 -c "
import json, sys

cs   = json.load(sys.stdin)
data = cs.get('cluster', {})
live = sorted(data.get('live_nodes', []))

if not live:
    print('  (none – is Solr running?)')
    sys.exit(0)

for n in live:
    print(f'  ✓  {n}')

print()
print(f'  Total: {len(live)} node(s)')

# Per-collection shard / replica breakdown
colls = data.get('collections', {})
if not colls:
    print()
    print('No collections found.')
    sys.exit(0)

print()
print('Collections:')
for cname, coll in colls.items():
    rf = coll.get('replicationFactor', '?')
    print(f'  [{cname}]  replicationFactor={rf}')
    for shard_name, shard in coll.get('shards', {}).items():
        state = shard.get('state', '?')
        print(f'    {shard_name}  ({state})')
        for rname, replica in shard.get('replicas', {}).items():
            is_leader = replica.get('leader', 'false') == 'true'
            rstate    = replica.get('state', '?')
            rnode     = replica.get('node_name', '?')
            leader_tag = ' ★ LEADER' if is_leader else ''
            ok_tag     = '' if rstate == 'active' else f'  ← {rstate.upper()}'
            print(f'      {rname}  {rnode}{leader_tag}{ok_tag}')
" || echo "  Could not reach Solr at ${SOLR_URL}"

# ── ZooKeeper ensemble status ─────────────────────────────────────────────────
echo ""
echo "ZooKeeper ensemble (ruok check):"
for port in 2181 2182 2183; do
  HOST="localhost"
  if echo ruok | nc -w 2 "${HOST}" "${port}" 2>/dev/null | grep -q imok; then
    echo "  ✓  ${HOST}:${port}  imok"
  else
    echo "  ✗  ${HOST}:${port}  unreachable"
  fi
done

# ── Redis ─────────────────────────────────────────────────────────────────────
echo ""
echo "Redis:"
if docker compose ps redis 2>/dev/null | grep -q "running"; then
  echo "  ✓  redis is running"
else
  echo "  ✗  redis is not running"
fi

echo ""
echo "═══════════════════════════════════════════════════════"

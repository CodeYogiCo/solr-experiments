#!/bin/bash
# Rolling deploy to bare-metal EC2 nodes (no Swarm, no Kubernetes)
# Usage: ./deploy.sh [IMAGE_TAG]
#
# Requires:
#   - terraform output already run (or pass IPs via env)
#   - SSH key available at ~/.ssh/id_rsa (or set SSH_KEY env)
#   - AWS CLI configured
set -euo pipefail

IMAGE_TAG="${1:-latest}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_rsa}"
SSH_USER="${SSH_USER:-ec2-user}"
STACK_DIR="/opt/solr-stack"
REGISTRY="ghcr.io/codeyogico/solr-experiments"

echo "Deploying tag: $IMAGE_TAG"

# ── Fetch node IPs from Terraform output ──────────────────────────────────────
cd "$(dirname "$0")"
SOLR_ZK_IPS=$(terraform output -json node_public_ips | jq -r '.[]')
REDIS_IP=$(terraform output -raw redis_public_ip)

ssh_run() {
  local ip="$1"
  shift
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "${SSH_USER}@${ip}" "$@"
}

# ── Rolling update: one node at a time ────────────────────────────────────────
NODE=1
for IP in $SOLR_ZK_IPS; do
  echo ""
  echo "═══ Updating node $NODE ($IP) ═══"

  # Pull new images
  ssh_run "$IP" "cd $STACK_DIR && \
    IMAGE_TAG=$IMAGE_TAG \
    docker compose pull"

  # Graceful ZooKeeper leader step-down before restart
  ssh_run "$IP" "echo reqs | nc -w 2 localhost 2181 || true"

  # Stop ZK, wait, restart (Solr reconnects automatically)
  ssh_run "$IP" "cd $STACK_DIR && \
    IMAGE_TAG=$IMAGE_TAG \
    docker compose up -d --no-deps --force-recreate zookeeper"

  echo "Waiting 20s for ZooKeeper to rejoin ensemble..."
  sleep 20

  # Restart Solr on this node
  ssh_run "$IP" "cd $STACK_DIR && \
    IMAGE_TAG=$IMAGE_TAG \
    docker compose up -d --no-deps --force-recreate solr"

  echo "Waiting 30s for Solr to rejoin SolrCloud..."
  sleep 30

  # Health check
  if ssh_run "$IP" "curl -sf http://localhost:8983/solr/admin/info/system > /dev/null"; then
    echo "Node $NODE is healthy"
  else
    echo "ERROR: Node $NODE failed health check – aborting rollout"
    exit 1
  fi

  NODE=$((NODE + 1))
done

# ── Update Redis (non-disruptive; it's standalone) ───────────────────────────
echo ""
echo "═══ Updating Redis ($REDIS_IP) ═══"
ssh_run "$REDIS_IP" "cd /opt/redis-stack && \
  IMAGE_TAG=$IMAGE_TAG \
  docker compose pull && \
  docker compose up -d --no-deps --force-recreate redis"

sleep 10
if ssh_run "$REDIS_IP" "docker compose -f /opt/redis-stack/docker-compose.yml exec redis redis-cli ping | grep -q PONG"; then
  echo "Redis is healthy"
else
  echo "WARNING: Redis health check failed"
fi

echo ""
echo "Deploy complete – all nodes running tag: $IMAGE_TAG"

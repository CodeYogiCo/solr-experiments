#!/bin/bash
# Deploy the manual-scale SolrCloud stack to any cloud VM via SSH.
#
# Works on: AWS EC2, GCP Compute Engine, Azure VM, DigitalOcean Droplet,
#           Hetzner, Linode, any Ubuntu/Debian/RHEL box with Docker.
#
# Usage:
#   ./scripts/deploy-to-vm.sh <VM_IP> [OPTIONS]
#
# Options:
#   --user     SSH user            (default: ubuntu)
#   --key      SSH private key     (default: ~/.ssh/id_rsa)
#   --tag      Image tag           (default: latest)
#   --nodes    Comma-separated Solr node numbers to start (default: 1,2)
#   --install  Install Docker on first run
#   --update   Pull new images and restart running nodes only
#
# Examples:
#   First deploy (install Docker + start 2 nodes):
#     ./scripts/deploy-to-vm.sh 54.12.34.56 --install --nodes 1,2
#
#   Add a node to a running cluster:
#     ./scripts/deploy-to-vm.sh 54.12.34.56 --nodes 3
#
#   Roll out a new image version:
#     ./scripts/deploy-to-vm.sh 54.12.34.56 --tag v1.2.3 --update
set -euo pipefail

VM_IP="${1:?Usage: $0 <VM_IP> [--user <user>] [--key <key>] [--tag <tag>] [--nodes 1,2] [--install] [--update]}"
shift

SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_rsa"
IMAGE_TAG="latest"
NODES="1,2"
INSTALL=false
UPDATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)    SSH_USER="$2";  shift 2 ;;
    --key)     SSH_KEY="$2";   shift 2 ;;
    --tag)     IMAGE_TAG="$2"; shift 2 ;;
    --nodes)   NODES="$2";     shift 2 ;;
    --install) INSTALL=true;   shift   ;;
    --update)  UPDATE=true;    shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=15 $SSH_USER@$VM_IP"
SCP="scp -i $SSH_KEY -o StrictHostKeyChecking=no -r"
REMOTE_DIR="/opt/solr-stack"

echo "Target: $SSH_USER@$VM_IP"
echo "Image tag: $IMAGE_TAG"
echo "Solr nodes: $NODES"
echo ""

# ── Step 1: Install Docker (first deploy only) ────────────────────────────────
if [ "$INSTALL" = true ]; then
  echo "── Installing Docker on $VM_IP ──"
  $SSH 'bash -s' << 'INSTALL_SCRIPT'
set -e
# Detect distro
if command -v apt-get &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
elif command -v dnf &>/dev/null; then
  dnf install -y docker
  systemctl enable --now docker
  # Docker Compose v2 plugin
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi
systemctl enable --now docker
usermod -aG docker $USER || true
echo "Docker installed: $(docker --version)"
INSTALL_SCRIPT
  echo "Docker installed."
fi

# ── Step 2: Copy repo files to VM ─────────────────────────────────────────────
echo ""
echo "── Syncing repo to $VM_IP:$REMOTE_DIR ──"
$SSH "mkdir -p $REMOTE_DIR"

# Sync only what's needed (skip .git, build artifacts, node_modules)
rsync -az \
  --exclude='.git' \
  --exclude='target/' \
  --exclude='__pycache__' \
  --exclude='*.class' \
  --exclude='.env' \
  -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" \
  ./ "$SSH_USER@$VM_IP:$REMOTE_DIR/"

# Copy .env if it exists locally (never committed to git)
if [ -f ".env" ]; then
  $SCP .env "$SSH_USER@$VM_IP:$REMOTE_DIR/.env"
fi

# ── Step 3: Deploy ────────────────────────────────────────────────────────────
echo ""
if [ "$UPDATE" = true ]; then
  # Rolling update – pull new images, restart only already-running nodes
  echo "── Rolling update (tag: $IMAGE_TAG) ──"
  $SSH "cd $REMOTE_DIR && \
    IMAGE_TAG=$IMAGE_TAG docker compose pull && \
    docker compose ps --format json 2>/dev/null | \
      python3 -c \"
import json, sys, subprocess, time
running = [c['Name'] for c in json.load(sys.stdin) if 'solr-node' in c['Name']]
for name in running:
    node = name.split('-')[-1]
    profile = f'solr-node-{node}'
    print(f'Restarting {name}...')
    subprocess.run(['docker', 'compose', '--profile', profile,
                    'up', '-d', '--no-deps', '--force-recreate', name], check=True)
    time.sleep(20)
    print(f'{name} restarted')
print('Update complete.')
\""
else
  # First deploy or explicit node start
  echo "── Starting ZooKeeper + Redis ──"
  $SSH "cd $REMOTE_DIR && \
    IMAGE_TAG=$IMAGE_TAG \
    docker compose up -d zookeeper1 zookeeper2 zookeeper3 redis"

  echo "Waiting for ZooKeeper quorum..."
  $SSH "until echo ruok | nc -w 2 localhost 2181 | grep -q imok; do sleep 3; done"
  echo "ZooKeeper is ready."

  echo ""
  echo "── Starting Solr nodes: $NODES ──"
  IFS=',' read -ra NODE_LIST <<< "$NODES"
  for NODE in "${NODE_LIST[@]}"; do
    echo "Starting solr-node-$NODE..."
    $SSH "cd $REMOTE_DIR && \
      IMAGE_TAG=$IMAGE_TAG \
      docker compose --profile solr-node-$NODE up -d solr-node-$NODE"
    sleep 10
  done
fi

# ── Step 4: Health check ──────────────────────────────────────────────────────
echo ""
echo "── Health check ──"
sleep 20
if $SSH "curl -sf http://localhost:8983/solr/admin/info/system > /dev/null"; then
  echo "Solr is healthy at http://$VM_IP:8983/solr"
else
  echo "WARNING: Solr not yet responding – check logs:"
  echo "  ssh -i $SSH_KEY $SSH_USER@$VM_IP 'docker compose -f $REMOTE_DIR/docker-compose.yml logs --tail=50'"
fi

# ── Step 5: Systemd unit (so stack restarts on VM reboot) ────────────────────
echo ""
echo "── Installing systemd auto-start ──"
$SSH "cat > /etc/systemd/system/solr-stack.service << 'UNIT'
[Unit]
Description=SolrCloud Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$REMOTE_DIR
EnvironmentFile=-$REMOTE_DIR/.env
ExecStart=/usr/bin/docker compose up -d zookeeper1 zookeeper2 zookeeper3 redis
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable solr-stack"

echo ""
echo "Done. Stack is running on $VM_IP."
echo ""
echo "Useful commands:"
echo "  SSH in:     ssh -i $SSH_KEY $SSH_USER@$VM_IP"
echo "  Add node:   ssh ... 'cd $REMOTE_DIR && make node-add NODE=3'"
echo "  Status:     ssh ... 'cd $REMOTE_DIR && make cluster-status'"
echo "  Update img: $0 $VM_IP --tag <new-tag> --update"

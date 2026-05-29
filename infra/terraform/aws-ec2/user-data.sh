#!/bin/bash
# EC2 bootstrap – Solr + ZooKeeper node (no Docker Swarm, plain Docker Compose)
# Variables injected by Terraform templatefile()
set -euo pipefail

ZOO_MY_ID="${zoo_my_id}"
EFS_ID="${efs_id}"
IMAGE_TAG="${image_tag}"
REGISTRY="${registry}"
IMAGE_REPO="${image_repo}"
REDIS_HOST="${redis_host}"
NODE_INDEX="${node_index}"
# NLB DNS name – single address for all Solr nodes, no IP lookup needed
ZK_HOST="${zk_lb_dns}:2181"
AWS_DEFAULT_REGION="$(curl -sf http://169.254.169.254/latest/meta-data/placement/region)"

# ── Install Docker ────────────────────────────────────────────────────────────
dnf update -y
dnf install -y docker amazon-efs-utils nfs-utils jq awscli

systemctl enable docker
systemctl start docker

# Docker Compose v2 plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL \
  "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ── Mount EFS ─────────────────────────────────────────────────────────────────
mkdir -p /mnt/efs/zookeeper /mnt/efs/solr

mount -t efs -o tls,_netdev "${EFS_ID}":/ /mnt/efs
mkdir -p /mnt/efs/zookeeper/${ZOO_MY_ID}/data \
         /mnt/efs/zookeeper/${ZOO_MY_ID}/datalog \
         /mnt/efs/solr/${ZOO_MY_ID}

# Persist mount in fstab
echo "${EFS_ID}:/ /mnt/efs efs _netdev,tls,iam 0 0" >> /etc/fstab

# No IP polling needed – Solr connects to the NLB, not individual ZK nodes.

# ── Write docker-compose.yml ──────────────────────────────────────────────────
mkdir -p /opt/solr-stack
cat > /opt/solr-stack/docker-compose.yml <<COMPOSE
version: "3.9"

services:
  zookeeper:
    image: ${REGISTRY}/${IMAGE_REPO}/zookeeper:${IMAGE_TAG}
    hostname: zookeeper${ZOO_MY_ID}
    network_mode: host
    environment:
      ZOO_MY_ID: "${ZOO_MY_ID}"
      ZOO_4LW_COMMANDS_WHITELIST: "mntr,conf,ruok,srvr,stat"
    volumes:
      - /mnt/efs/zookeeper/${ZOO_MY_ID}/data:/data
      - /mnt/efs/zookeeper/${ZOO_MY_ID}/datalog:/datalog
      - /opt/solr-stack/zoo.cfg:/conf/zoo.cfg:ro
    restart: unless-stopped
    logging:
      driver: awslogs
      options:
        awslogs-group: /solr-stack/zookeeper
        awslogs-region: ${AWS_DEFAULT_REGION}
        awslogs-stream: "node-${ZOO_MY_ID}"
        awslogs-create-group: "true"

  solr:
    image: ${REGISTRY}/${IMAGE_REPO}/solr:${IMAGE_TAG}
    hostname: solr${ZOO_MY_ID}
    network_mode: host
    environment:
      ZK_HOST: "${ZK_HOST}"
      SOLR_HEAP: "2g"
      REDIS_HOST: "${REDIS_HOST}"
    volumes:
      - /mnt/efs/solr/${ZOO_MY_ID}:/var/solr/data
    depends_on:
      - zookeeper
    restart: unless-stopped
    logging:
      driver: awslogs
      options:
        awslogs-group: /solr-stack/solr
        awslogs-region: ${AWS_DEFAULT_REGION}
        awslogs-stream: "node-${ZOO_MY_ID}"
        awslogs-create-group: "true"
COMPOSE

# ── Write zoo.cfg with real peer IPs ─────────────────────────────────────────
cat > /opt/solr-stack/zoo.cfg <<ZOO
tickTime=2000
initLimit=10
syncLimit=5
dataDir=/data
dataLogDir=/datalog
clientPort=2181
maxClientCnxns=200
autopurge.snapRetainCount=5
autopurge.purgeInterval=24
4lw.commands.whitelist=mntr,conf,ruok,srvr,stat
$(echo -e "$ZK_SERVER_LINES")
ZOO

# ── Pull images & start ───────────────────────────────────────────────────────
cd /opt/solr-stack
docker compose pull
docker compose up -d

# ── Systemd unit so it restarts on reboot ────────────────────────────────────
cat > /etc/systemd/system/solr-stack.service <<UNIT
[Unit]
Description=Solr Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/solr-stack
ExecStart=/usr/local/lib/docker/cli-plugins/docker-compose up -d
ExecStop=/usr/local/lib/docker/cli-plugins/docker-compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable solr-stack

echo "Bootstrap complete – ZooKeeper node ${ZOO_MY_ID} + Solr running"

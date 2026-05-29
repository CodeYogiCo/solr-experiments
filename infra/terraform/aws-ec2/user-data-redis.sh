#!/bin/bash
# EC2 bootstrap – Redis node (plain Docker Compose, no Swarm)
set -euo pipefail

EFS_ID="${efs_id}"
IMAGE_TAG="${image_tag}"
REGISTRY="${registry}"
IMAGE_REPO="${image_repo}"
AWS_DEFAULT_REGION="$(curl -sf http://169.254.169.254/latest/meta-data/placement/region)"

dnf update -y
dnf install -y docker amazon-efs-utils nfs-utils awscli

systemctl enable docker
systemctl start docker

mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL \
  "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ── Mount EFS ─────────────────────────────────────────────────────────────────
mkdir -p /mnt/efs/redis
mount -t efs -o tls,_netdev "${EFS_ID}":/redis /mnt/efs/redis
echo "${EFS_ID}:/redis /mnt/efs/redis efs _netdev,tls,iam 0 0" >> /etc/fstab

# ── Fetch Redis password from SSM Parameter Store ─────────────────────────────
REDIS_PASSWORD=$(aws ssm get-parameter \
  --name "/solr-stack/redis-password" \
  --with-decryption \
  --query Parameter.Value \
  --output text 2>/dev/null || echo "changeme")

# ── Write docker-compose.yml ──────────────────────────────────────────────────
mkdir -p /opt/redis-stack
cat > /opt/redis-stack/docker-compose.yml <<COMPOSE
version: "3.9"
services:
  redis:
    image: ${REGISTRY}/${IMAGE_REPO}/redis:${IMAGE_TAG}
    network_mode: host
    command:
      - redis-server
      - /usr/local/etc/redis/redis.conf
      - --requirepass
      - "${REDIS_PASSWORD}"
    volumes:
      - /mnt/efs/redis:/data
    restart: unless-stopped
    logging:
      driver: awslogs
      options:
        awslogs-group: /solr-stack/redis
        awslogs-region: ${AWS_DEFAULT_REGION}
        awslogs-stream: redis
        awslogs-create-group: "true"
COMPOSE

cd /opt/redis-stack
docker compose pull
docker compose up -d

cat > /etc/systemd/system/redis-stack.service <<UNIT
[Unit]
Description=Redis Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/redis-stack
ExecStart=/usr/local/lib/docker/cli-plugins/docker-compose up -d
ExecStop=/usr/local/lib/docker/cli-plugins/docker-compose down
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable redis-stack

echo "Redis bootstrap complete"

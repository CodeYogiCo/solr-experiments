#!/bin/bash
set -euo pipefail

NFS_IP="${nfs_ip}"
NFS_PATH="${nfs_path}"
REGISTRY="${registry}"
IMAGE_REPO="${image_repo}"
IMAGE_TAG="${image_tag}"

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg nfs-common

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

mkdir -p /mnt/nfs/redis
mount -t nfs "${NFS_IP}:${NFS_PATH}" /mnt/nfs
echo "${NFS_IP}:${NFS_PATH} /mnt/nfs nfs defaults,_netdev 0 0" >> /etc/fstab
mkdir -p /mnt/nfs/redis

REDIS_PASSWORD=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/attributes/redis-password" \
  2>/dev/null || echo "changeme")

mkdir -p /opt/redis-stack
cat > /opt/redis-stack/docker-compose.yml << COMPOSE
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
      - /mnt/nfs/redis:/data
    restart: unless-stopped
    logging:
      driver: gcplogs
      options:
        labels: "component=redis"
COMPOSE

cd /opt/redis-stack && docker compose pull && docker compose up -d

cat > /etc/systemd/system/redis-stack.service << UNIT
[Unit]
Description=Redis Stack
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/redis-stack
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload && systemctl enable redis-stack
echo "GCP Redis bootstrap complete"

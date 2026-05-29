#!/bin/bash
# GCP Compute Engine startup script – Solr + ZooKeeper node
# Injected via instance metadata; runs once on first boot.
set -euo pipefail

ZOO_MY_ID="${zoo_my_id}"
NFS_IP="${nfs_ip}"
NFS_PATH="${nfs_path}"
REGISTRY="${registry}"
IMAGE_REPO="${image_repo}"
IMAGE_TAG="${image_tag}"
REDIS_HOST="${redis_internal}"
ZK_LB_IP="${zk_lb_ip}"
ZK_HOST="${ZK_LB_IP}:2181"

# ── Install Docker ────────────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg nfs-common

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable --now docker

# ── Mount Filestore NFS ───────────────────────────────────────────────────────
mkdir -p /mnt/nfs/zookeeper/${ZOO_MY_ID}/data \
         /mnt/nfs/zookeeper/${ZOO_MY_ID}/datalog \
         /mnt/nfs/solr/${ZOO_MY_ID}

mount -t nfs "${NFS_IP}:${NFS_PATH}" /mnt/nfs
echo "${NFS_IP}:${NFS_PATH} /mnt/nfs nfs defaults,_netdev 0 0" >> /etc/fstab

mkdir -p /mnt/nfs/zookeeper/${ZOO_MY_ID}/data \
         /mnt/nfs/zookeeper/${ZOO_MY_ID}/datalog \
         /mnt/nfs/solr/${ZOO_MY_ID}

# ── Determine ZooKeeper peer addresses ───────────────────────────────────────
# Peers are on the same VPC subnet; use internal IPs from GCP metadata
SELF_IP=$(curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")

# ZK server.N entries use internal IPs – each instance writes its own line
# and reads others from a shared NFS file
mkdir -p /mnt/nfs/zk-bootstrap
echo "${SELF_IP}" > /mnt/nfs/zk-bootstrap/node-${ZOO_MY_ID}.ip

# Wait until all 3 nodes have written their IPs (up to 5 min)
for i in $(seq 1 60); do
  COUNT=$(ls /mnt/nfs/zk-bootstrap/node-*.ip 2>/dev/null | wc -l)
  [ "$COUNT" -eq 3 ] && break
  echo "Waiting for all ZK nodes to register ($COUNT/3)... ($i/60)"
  sleep 5
done

ZK1=$(cat /mnt/nfs/zk-bootstrap/node-1.ip 2>/dev/null || echo "127.0.0.1")
ZK2=$(cat /mnt/nfs/zk-bootstrap/node-2.ip 2>/dev/null || echo "127.0.0.1")
ZK3=$(cat /mnt/nfs/zk-bootstrap/node-3.ip 2>/dev/null || echo "127.0.0.1")

# ── Write docker-compose.yml ──────────────────────────────────────────────────
mkdir -p /opt/solr-stack
cat > /opt/solr-stack/zoo.cfg << ZOO
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
server.1=${ZK1}:2888:3888
server.2=${ZK2}:2888:3888
server.3=${ZK3}:2888:3888
ZOO

cat > /opt/solr-stack/docker-compose.yml << COMPOSE
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
      - /mnt/nfs/zookeeper/${ZOO_MY_ID}/data:/data
      - /mnt/nfs/zookeeper/${ZOO_MY_ID}/datalog:/datalog
      - /opt/solr-stack/zoo.cfg:/conf/zoo.cfg:ro
    restart: unless-stopped
    logging:
      driver: gcplogs
      options:
        gcp-log-cmd: "true"
        labels: "component=zookeeper,node=${ZOO_MY_ID}"

  solr:
    image: ${REGISTRY}/${IMAGE_REPO}/solr:${IMAGE_TAG}
    hostname: solr${ZOO_MY_ID}
    network_mode: host
    environment:
      SOLR_MODE: production
      ZK_HOST: "${ZK_HOST}"
      REDIS_HOST: "${REDIS_HOST}"
      SOLR_HEAP: "2g"
    volumes:
      - /mnt/nfs/solr/${ZOO_MY_ID}:/var/solr/data
    depends_on: [zookeeper]
    restart: unless-stopped
    logging:
      driver: gcplogs
      options:
        gcp-log-cmd: "true"
        labels: "component=solr,node=${ZOO_MY_ID}"
COMPOSE

cd /opt/solr-stack
docker compose pull
docker compose up -d

# ── Systemd unit ──────────────────────────────────────────────────────────────
cat > /etc/systemd/system/solr-stack.service << UNIT
[Unit]
Description=SolrCloud Stack
Requires=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/solr-stack
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable solr-stack
echo "GCP bootstrap complete – ZooKeeper node ${ZOO_MY_ID} + Solr running"

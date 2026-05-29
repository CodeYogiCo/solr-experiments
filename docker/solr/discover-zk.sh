#!/bin/bash
# ZooKeeper auto-discovery script.
# Outputs a comma-separated ZK connection string: host1:2181,host2:2181,...
#
# Discovery order (first method that returns live hosts wins):
#
#   1. ZK_HOST env var           – explicit override, always wins
#   2. Docker / internal DNS     – works in docker-compose and Kubernetes
#   3. Consul HTTP API           – works on any VM running a Consul agent
#   4. DNS SRV record            – works with Consul DNS / Route53 / Cloud DNS
#   5. AWS EC2 instance tags     – tags Role=zookeeper, Project=<ZK_PROJECT>
#   6. GCP instance labels       – label role=zookeeper, project=<ZK_PROJECT>
#   7. Azure VM tags             – tag Role=zookeeper, Project=<ZK_PROJECT>
#   8. Fail with a clear message
#
# Environment variables:
#   ZK_HOST              – explicit host list (skips all discovery)
#   ZK_PORT              – ZooKeeper client port (default: 2181)
#   ZK_DISCOVERY_HOSTS   – space-separated DNS names to probe (default: "zookeeper1 zookeeper2 zookeeper3")
#   ZK_DISCOVERY_DOMAIN  – DNS domain for SRV lookup (e.g. "solr-cluster.internal")
#   ZK_PROJECT           – tag/label value used to scope cloud discovery (default: "solr-stack")
#   CONSUL_HTTP_ADDR     – Consul API address (default: http://consul:8500)
set -euo pipefail

ZK_PORT="${ZK_PORT:-2181}"
ZK_PROJECT="${ZK_PROJECT:-solr-stack}"
CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-http://consul:8500}"

log() { echo "[zk-discover] $*" >&2; }

# ── helpers ───────────────────────────────────────────────────────────────────

# Test whether a single host:port is actually reachable
zk_alive() {
  local host="$1" port="${2:-$ZK_PORT}"
  timeout 3 bash -c "echo ruok | nc -w 2 ${host} ${port}" 2>/dev/null | grep -q imok
}

# Build a connection string from a list of "host port" pairs, keeping only live ones
build_connstr() {
  local connstr=""
  while IFS=" " read -r host port; do
    [ -z "$host" ] && continue
    port="${port:-$ZK_PORT}"
    if zk_alive "$host" "$port"; then
      connstr="${connstr:+$connstr,}${host}:${port}"
      log "  ✓  ${host}:${port}"
    else
      log "  ✗  ${host}:${port} (unreachable)"
    fi
  done
  echo "$connstr"
}

# ── Method 1: explicit ZK_HOST ────────────────────────────────────────────────
if [ -n "${ZK_HOST:-}" ]; then
  log "Method 1 – using explicit ZK_HOST=$ZK_HOST"
  echo "$ZK_HOST"
  exit 0
fi

# ── Method 2: Docker / internal DNS probe ─────────────────────────────────────
log "Method 2 – DNS probe (Docker / Kubernetes / /etc/hosts)"
DNS_HOSTS="${ZK_DISCOVERY_HOSTS:-zookeeper1 zookeeper2 zookeeper3}"
CONNSTR=""
for host in $DNS_HOSTS; do
  # getent resolves Docker bridge names, k8s service names, /etc/hosts entries
  if getent hosts "$host" > /dev/null 2>&1; then
    if zk_alive "$host"; then
      CONNSTR="${CONNSTR:+$CONNSTR,}${host}:${ZK_PORT}"
      log "  ✓  $host resolved and alive"
    else
      log "  ~  $host resolved but ZK not responding yet"
    fi
  fi
done

if [ -n "$CONNSTR" ]; then
  log "Method 2 succeeded: $CONNSTR"
  echo "$CONNSTR"
  exit 0
fi

# ── Method 3: Consul HTTP API ─────────────────────────────────────────────────
log "Method 3 – Consul HTTP API ($CONSUL_HTTP_ADDR)"
if curl -sf --max-time 3 "${CONSUL_HTTP_ADDR}/v1/health/service/zookeeper?passing=true" \
    > /tmp/consul-zk.json 2>/dev/null; then

  CONNSTR=$(python3 - << 'PY'
import json, sys
try:
    services = json.load(open('/tmp/consul-zk.json'))
    hosts = [
        f"{s['Service']['Address'] or s['Node']['Address']}:{s['Service']['Port']}"
        for s in services
    ]
    print(','.join(hosts))
except Exception as e:
    print('', end='')
PY
  )

  if [ -n "$CONNSTR" ]; then
    log "Method 3 succeeded: $CONNSTR"
    echo "$CONNSTR"
    exit 0
  fi
fi
log "  Consul not available or no healthy zookeeper service registered"

# ── Method 4: DNS SRV record ──────────────────────────────────────────────────
log "Method 4 – DNS SRV (_zookeeper._tcp.${ZK_DISCOVERY_DOMAIN:-})"
if [ -n "${ZK_DISCOVERY_DOMAIN:-}" ]; then
  SRV_RECORD="_zookeeper._tcp.${ZK_DISCOVERY_DOMAIN}"
  CONNSTR=$(dig +short SRV "$SRV_RECORD" 2>/dev/null | \
    awk '{printf "%s:%s\n", $4, $3}' | \
    while IFS=: read -r host port; do
      host="${host%.}"   # strip trailing dot
      if zk_alive "$host" "$port"; then
        echo -n "${host}:${port},"
      fi
    done | sed 's/,$//')

  if [ -n "$CONNSTR" ]; then
    log "Method 4 succeeded: $CONNSTR"
    echo "$CONNSTR"
    exit 0
  fi
fi
log "  No DNS SRV records found (set ZK_DISCOVERY_DOMAIN to enable)"

# ── Method 5: AWS EC2 instance tags ──────────────────────────────────────────
log "Method 5 – AWS EC2 tags (Role=zookeeper, Project=$ZK_PROJECT)"
if curl -sf --max-time 2 \
    "http://169.254.169.254/latest/meta-data/placement/region" \
    > /tmp/aws-region 2>/dev/null; then

  AWS_REGION=$(cat /tmp/aws-region)
  log "  Running on AWS in region $AWS_REGION"

  IPS=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag:Role,Values=zookeeper" \
      "Name=tag:Project,Values=${ZK_PROJECT}" \
      "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].PrivateIpAddress" \
    --output text 2>/dev/null | tr '\t' '\n')

  CONNSTR=$(echo "$IPS" | while read -r ip; do
    [ -z "$ip" ] && continue
    if zk_alive "$ip"; then
      echo -n "${ip}:${ZK_PORT},"
    fi
  done | sed 's/,$//')

  if [ -n "$CONNSTR" ]; then
    log "Method 5 succeeded: $CONNSTR"
    echo "$CONNSTR"
    exit 0
  fi
  log "  No tagged ZooKeeper instances found or none reachable"
else
  log "  Not running on AWS (metadata endpoint unreachable)"
fi

# ── Method 6: GCP instance labels ────────────────────────────────────────────
log "Method 6 – GCP instance labels (role=zookeeper)"
if curl -sf --max-time 2 \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/project/project-id" \
    > /tmp/gcp-project 2>/dev/null; then

  GCP_PROJECT=$(cat /tmp/gcp-project)
  GCP_ZONE=$(curl -sf --max-time 2 \
    -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/zone" | \
    awk -F/ '{print $NF}')
  log "  Running on GCP project=$GCP_PROJECT zone=$GCP_ZONE"

  IPS=$(gcloud compute instances list \
    --project="$GCP_PROJECT" \
    --filter="labels.role=zookeeper AND labels.project=${ZK_PROJECT} AND status=RUNNING" \
    --format="value(networkInterfaces[0].networkIP)" 2>/dev/null)

  CONNSTR=$(echo "$IPS" | while read -r ip; do
    [ -z "$ip" ] && continue
    if zk_alive "$ip"; then
      echo -n "${ip}:${ZK_PORT},"
    fi
  done | sed 's/,$//')

  if [ -n "$CONNSTR" ]; then
    log "Method 6 succeeded: $CONNSTR"
    echo "$CONNSTR"
    exit 0
  fi
  log "  No labelled GCP instances found or none reachable"
else
  log "  Not running on GCP"
fi

# ── Method 7: Azure VM tags ───────────────────────────────────────────────────
log "Method 7 – Azure VM tags (Role=zookeeper)"
if curl -sf --max-time 2 \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/compute/subscriptionId?api-version=2021-02-01&format=text" \
    > /tmp/azure-sub 2>/dev/null; then

  AZURE_SUB=$(cat /tmp/azure-sub)
  AZURE_RG=$(curl -sf -H "Metadata: true" \
    "http://169.254.169.254/metadata/instance/compute/resourceGroupName?api-version=2021-02-01&format=text")
  log "  Running on Azure sub=$AZURE_SUB rg=$AZURE_RG"

  TOKEN=$(curl -sf -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

  IPS=$(curl -sf \
    -H "Authorization: Bearer $TOKEN" \
    "https://management.azure.com/subscriptions/${AZURE_SUB}/resourceGroups/${AZURE_RG}/providers/Microsoft.Compute/virtualMachines?api-version=2023-03-01" \
    | python3 - << 'PY'
import json, sys
data = json.load(sys.stdin)
for vm in data.get('value', []):
    tags = vm.get('tags', {})
    if tags.get('Role') == 'zookeeper':
        # NIC lookup needed for IP – simplified: print VM name as hint
        print(vm['name'])
PY
  )
  log "  Azure ZK VMs found: $IPS (IP lookup requires NIC API – use Consul or DNS instead)"
  # Azure IP resolution requires additional NIC API calls; DNS/Consul is recommended on Azure
fi

# ── All methods exhausted ─────────────────────────────────────────────────────
log ""
log "ERROR: Could not discover any live ZooKeeper nodes."
log ""
log "Fix options:"
log "  A) Set ZK_HOST=host1:2181,host2:2181 explicitly"
log "  B) Ensure ZK containers are named zookeeper1/2/3 on the same Docker network"
log "  C) Run a Consul agent and register ZK with service name 'zookeeper'"
log "  D) On AWS: tag ZK EC2 instances with Role=zookeeper and Project=${ZK_PROJECT}"
log "  E) On GCP: label ZK instances with role=zookeeper and project=${ZK_PROJECT}"
log "  F) Set ZK_DISCOVERY_DOMAIN and create DNS SRV records"
exit 1

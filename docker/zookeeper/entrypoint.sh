#!/bin/bash
# ZooKeeper entrypoint.
# Writes myid, optionally self-registers with Consul, then starts ZK.
set -euo pipefail

: "${ZOO_MY_ID:?ZOO_MY_ID must be set (1, 2 or 3)}"

echo "${ZOO_MY_ID}" > /data/myid

export SERVER_JVMFLAGS="${SERVER_JVMFLAGS:--Xmx512m -Xms512m \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=50 \
  -Dcom.sun.jndi.rmi.object.trustURLCodebase=false \
  -Dcom.sun.jndi.cosnaming.object.trustURLCodebase=false}"

# ── Optional: register with Consul so Solr can discover us ───────────────────
# Consul is queried by /discover-zk.sh Method 3.
# This registration is best-effort; ZK still starts even if Consul is absent.
register_with_consul() {
  local consul_addr="${CONSUL_HTTP_ADDR:-http://consul:8500}"
  local my_ip
  my_ip=$(hostname -i 2>/dev/null | awk '{print $1}' || echo "")

  if [ -z "$my_ip" ]; then
    echo "[consul-register] Could not determine own IP; skipping registration"
    return
  fi

  local payload
  payload=$(cat <<JSON
{
  "Name":    "zookeeper",
  "ID":      "zookeeper-${ZOO_MY_ID}",
  "Address": "${my_ip}",
  "Port":    2181,
  "Tags":    ["zookeeper", "node-${ZOO_MY_ID}"],
  "Check": {
    "TCP":                          "${my_ip}:2181",
    "Interval":                     "15s",
    "Timeout":                      "5s",
    "DeregisterCriticalServiceAfter": "60s"
  }
}
JSON
  )

  if curl -sf --max-time 3 \
      -X PUT \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${consul_addr}/v1/agent/service/register" > /dev/null 2>&1; then
    echo "[consul-register] Registered as zookeeper-${ZOO_MY_ID} (${my_ip}:2181)"
  else
    echo "[consul-register] Consul not available – skipping (Solr will use DNS discovery instead)"
  fi
}

# Register in background so ZK doesn't wait on it
register_with_consul &

# ── Start ZooKeeper ──────────────────────────────────────────────────────────
exec /docker-entrypoint.sh zkServer.sh start-foreground

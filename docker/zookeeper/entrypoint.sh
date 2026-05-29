#!/bin/bash
set -euo pipefail

# ZOO_MY_ID must be set (1, 2, or 3)
: "${ZOO_MY_ID:?ZOO_MY_ID must be set}"

echo "${ZOO_MY_ID}" > /data/myid

# Allow SERVER_JVMFLAGS for production GC tuning
export SERVER_JVMFLAGS="${SERVER_JVMFLAGS:--Xmx512m -Xms512m \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=50 \
  -Dcom.sun.jndi.rmi.object.trustURLCodebase=false \
  -Dcom.sun.jndi.cosnaming.object.trustURLCodebase=false}"

exec /docker-entrypoint.sh zkServer.sh start-foreground

FROM zookeeper:3.8.4 AS base

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    netcat-openbsd \
    curl \
  && rm -rf /var/lib/apt/lists/*

# Production zoo.cfg baked in; runtime values come from environment variables
COPY config/zoo.cfg /conf/zoo.cfg
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Data dirs with correct ownership
RUN mkdir -p /data /datalog && chown -R zookeeper:zookeeper /data /datalog

USER zookeeper

EXPOSE 2181 2888 3888 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
  CMD echo ruok | nc -w 2 localhost 2181 | grep -q imok || exit 1

ENTRYPOINT ["/entrypoint.sh"]

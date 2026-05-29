FROM solr:9.6.0-slim AS base

USER root

# Install utilities needed for ZK wait + health checks
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    netcat-openbsd \
    jq \
  && rm -rf /var/lib/apt/lists/*

# ── Security hardening ────────────────────────────────────────────────────────
# Remove default example cores; we manage collections via ZooKeeper
RUN rm -rf /var/solr/data/configsets/sample_techproducts_configs \
           /var/solr/data/configsets/_default/conf/managed-schema

# ── Custom log config ─────────────────────────────────────────────────────────
COPY config/log4j2.xml /var/solr/log4j2.xml
ENV LOG4J_PROPS=/var/solr/log4j2.xml

# ── Lib: Redis plugin JAR (built externally via make plugin-install) ───────────
RUN mkdir -p /opt/solr/server/solr/lib
COPY lib/*.jar /opt/solr/server/solr/lib/

# ── Solr configuration for SolrCloud ─────────────────────────────────────────
COPY config/solr.xml /var/solr/data/solr.xml

# ── Best Buy configset ────────────────────────────────────────────────────────
COPY ../../solr-config/bestbuy/ /opt/solr/server/solr/configsets/bestbuy/conf/

# ── Entry-point wrapper ───────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER solr

EXPOSE 8983

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD curl -sf http://localhost:8983/solr/admin/info/system || exit 1

ENTRYPOINT ["/entrypoint.sh"]

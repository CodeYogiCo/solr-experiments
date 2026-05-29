################################################################################
# Stage 1 – compile the Solr Redis plugin inside Docker
# This means `docker compose up --build` works with no local Java/Maven needed.
################################################################################
FROM maven:3.9-eclipse-temurin-17-slim AS plugin-builder

WORKDIR /build
COPY solr-redis-plugin/pom.xml .
# Download dependencies first (layer-cached unless pom.xml changes)
RUN mvn dependency:go-offline -q

COPY solr-redis-plugin/src/ src/
RUN mvn package -DskipTests -q

################################################################################
# Stage 2 – production Solr image
################################################################################
FROM solr:9.6.0-slim

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    netcat-openbsd \
    jq \
  && rm -rf /var/lib/apt/lists/*

# Remove default example cores; collections managed via ZooKeeper
RUN rm -rf /var/solr/data/configsets/sample_techproducts_configs \
           /var/solr/data/configsets/_default/conf/managed-schema

# ── Custom log config ─────────────────────────────────────────────────────────
COPY docker/solr/config/log4j2.xml /var/solr/log4j2.xml
ENV LOG4J_PROPS=/var/solr/log4j2.xml

# ── Redis plugin JAR (compiled in stage 1) ────────────────────────────────────
RUN mkdir -p /opt/solr/server/solr/lib
COPY --from=plugin-builder /build/target/solr-redis-plugin-*.jar \
     /opt/solr/server/solr/lib/

# ── SolrCloud config ──────────────────────────────────────────────────────────
COPY docker/solr/config/solr.xml /var/solr/data/solr.xml

# ── Best Buy configset ────────────────────────────────────────────────────────
COPY solr-config/bestbuy/ /opt/solr/server/solr/configsets/bestbuy/conf/

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY docker/solr/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER solr

EXPOSE 8983

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD curl -sf http://localhost:8983/solr/admin/info/system || exit 1

ENTRYPOINT ["/entrypoint.sh"]

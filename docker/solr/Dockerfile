################################################################################
# Stage 1 – compile the Solr Redis plugin inside Docker (Gradle)
# This means `docker compose up --build` works with no local Java/Gradle needed.
################################################################################
FROM eclipse-temurin:17-jdk-jammy AS plugin-builder

WORKDIR /build

# Copy the Gradle wrapper + build scripts first so dependency resolution is
# layer-cached unless the build config changes.
COPY solr-redis-plugin/gradlew ./
COPY solr-redis-plugin/gradle ./gradle
COPY solr-redis-plugin/settings.gradle solr-redis-plugin/build.gradle ./
RUN ./gradlew --no-daemon dependencies > /dev/null 2>&1 || true

COPY solr-redis-plugin/src/ src/
# Build the shaded jar (skips tests; the connection-dependent paths are covered
# by the integration smoke test in CI).
RUN ./gradlew --no-daemon clean shadowJar

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
COPY --from=plugin-builder /build/build/libs/solr-redis-plugin-*.jar \
     /opt/solr/server/solr/lib/

# ── SolrCloud config ──────────────────────────────────────────────────────────
COPY docker/solr/config/solr.xml /var/solr/data/solr.xml

# ── Best Buy configset ────────────────────────────────────────────────────────
COPY solr-config/bestbuy/ /opt/solr/server/solr/configsets/bestbuy/conf/

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY docker/solr/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The COPYs above ran as root and left /var/solr/data root-owned. Solr runs as
# the unprivileged `solr` user and needs to create the embedded ZooKeeper data
# dir (/var/solr/data/zoo_data) and core data here, so hand ownership back.
# (A fresh named volume mounted at /var/solr/data inherits this ownership.)
RUN chown -R solr:solr /var/solr

USER solr

EXPOSE 8983

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
  CMD curl -sf http://localhost:8983/solr/admin/info/system || exit 1

ENTRYPOINT ["/entrypoint.sh"]

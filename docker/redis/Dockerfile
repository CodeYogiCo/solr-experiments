FROM redis:7.2-alpine AS base

RUN apk add --no-cache curl

COPY redis.conf /usr/local/etc/redis/redis.conf

EXPOSE 6379

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=5 \
  CMD redis-cli ping | grep -q PONG || exit 1

CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]

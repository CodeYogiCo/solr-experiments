package com.solrexperiments.redis;

import org.apache.solr.common.util.NamedList;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import redis.clients.jedis.JedisPool;
import redis.clients.jedis.JedisPoolConfig;
import redis.clients.jedis.Protocol;

import java.time.Duration;

/**
 * Singleton Jedis pool shared across all Solr cores in this JVM.
 * Initialized lazily on first component prepare(); closed on JVM shutdown.
 */
public final class RedisConnectionManager {

    private static final Logger log = LoggerFactory.getLogger(RedisConnectionManager.class);

    private static volatile RedisConnectionManager instance;

    private JedisPool pool;

    private RedisConnectionManager() {}

    public static RedisConnectionManager getInstance() {
        if (instance == null) {
            synchronized (RedisConnectionManager.class) {
                if (instance == null) {
                    instance = new RedisConnectionManager();
                }
            }
        }
        return instance;
    }

    /**
     * (Re)initialise the pool. Safe to call multiple times; only builds a new
     * pool when configuration has actually changed (or on first call).
     */
    public synchronized void init(NamedList<?> args) {
        if (pool != null && !pool.isClosed()) {
            return;
        }

        String host     = getString(args, "redis.host", "redis");
        int    port     = getInt(args, "redis.port", Protocol.DEFAULT_PORT);
        String password = getString(args, "redis.password", null);
        int    timeout  = getInt(args, "redis.timeout", 2000);
        int    maxTotal = getInt(args, "redis.pool.maxTotal", 16);
        int    maxIdle  = getInt(args, "redis.pool.maxIdle", 8);

        JedisPoolConfig cfg = new JedisPoolConfig();
        cfg.setMaxTotal(maxTotal);
        cfg.setMaxIdle(maxIdle);
        cfg.setMinIdle(2);
        cfg.setTestOnBorrow(false);
        cfg.setTestOnReturn(false);
        cfg.setTestWhileIdle(true);
        cfg.setMinEvictableIdleTime(Duration.ofSeconds(60));
        cfg.setTimeBetweenEvictionRuns(Duration.ofSeconds(30));
        cfg.setBlockWhenExhausted(true);
        cfg.setMaxWait(Duration.ofMillis(timeout));

        if (password != null && !password.isBlank()) {
            pool = new JedisPool(cfg, host, port, timeout, password);
        } else {
            pool = new JedisPool(cfg, host, port, timeout);
        }

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            if (pool != null && !pool.isClosed()) {
                log.info("Closing Redis connection pool on shutdown");
                pool.close();
            }
        }));

        log.info("Redis connection pool initialised: {}:{} maxTotal={}", host, port, maxTotal);
    }

    public JedisPool getPool() {
        if (pool == null || pool.isClosed()) {
            throw new IllegalStateException("Redis pool is not initialised – call init() first");
        }
        return pool;
    }

    // ── helpers ──────────────────────────────────────────────────────────────

    private static String getString(NamedList<?> args, String key, String defaultVal) {
        Object v = args.get(key);
        return (v instanceof String s && !s.isBlank()) ? s : defaultVal;
    }

    private static int getInt(NamedList<?> args, String key, int defaultVal) {
        Object v = args.get(key);
        if (v instanceof Number n) return n.intValue();
        if (v instanceof String s) {
            try { return Integer.parseInt(s.trim()); } catch (NumberFormatException ignored) {}
        }
        return defaultVal;
    }
}

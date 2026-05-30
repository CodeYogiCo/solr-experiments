# Solr + Redis local playground

A single-node **SolrCloud** (with ZooKeeper embedded in the Solr process) plus
**Redis**, wired together with a custom Solr plugin that does real-time
**store-availability filtering** from Redis bitmaps — over a Best Buy
e-commerce dataset.

Everything runs locally with one `docker compose` command. No external
ZooKeeper, no cloud, no orchestrator.

```
┌──────────────────────────────────┐
│  solr container                  │
│  ├── Solr            :8983       │      ┌─────────────────────┐
│  └── ZooKeeper (embedded, -DzkRun)│ ◄──► │  redis container    │
│       :9983 (internal)           │      │  :6379  (bitmaps)   │
└──────────────────────────────────┘      └─────────────────────┘
```

---

## Quick start

```bash
make up            # build images + start Solr + Redis, auto-creates 'bestbuy'
make load-data     # index Best Buy products into Solr
make seed-redis    # seed sample store-availability bitmaps in Redis
make query         # run a sample availability filter + annotate query
```

- Solr UI → http://localhost:8983/solr
- Redis   → `localhost:6379` (no password — local only)

`make help` lists every target. Other handy ones:

```bash
make logs          # tail Solr + Redis logs
make restart       # restart the stack (keeps data volumes)
make down          # stop the stack and remove volumes
make clean         # down -v + clean the plugin build output
```

> The plugin is compiled **inside** the Solr Docker image (multi-stage build),
> so `make up` works with no local Java or Gradle installed.

---

## The Redis store-availability plugin

Two custom Solr extension points (`solr-redis-plugin/`, a Gradle project) that
check a Redis bitmap at query time. Which extension point you want depends on
what you're asking for:

- **Filter** out-of-stock docs → a **PostFilter** (`{!store_avail}`, used as `fq`).
  Filtering happens inside the collection chain, *before* the top-N collector,
  so `rows`, `start`, `numFound`, and facet counts all reflect the filtered set.
- **Annotate** every doc with availability → a **DocTransformer**
  (`[store_avail]`, used in `fl`). Keeps all docs and leaves `numFound`/facets
  untouched.

**Local params** (both): `id` (required, the store ID) and `field` (optional,
the numeric SKU field; default `sku`).

**Filter — drop docs not in stock at store 1000:**
```bash
curl 'http://localhost:8983/solr/bestbuy/select?q=laptop&fq={!store_avail id=1000}&fl=sku,name'
```

**Annotate — keep all docs, add a `storeAvailable` boolean:**
```bash
curl 'http://localhost:8983/solr/bestbuy/select?q=laptop&fl=sku,name,storeAvailable:[store_avail id=1000]'
```

### How the bitmaps work

- Key: `store:{storeId}:availability`
- Bit offset: the numeric product **SKU** (read per-doc from the `sku` DocValues
  field — not the stored field, which is unreliable inside a transformer)
- `SETBIT store:1000:availability 7823109 1` → SKU 7823109 in stock at store 1000
- `GETBIT store:1000:availability 7823109`   → O(1) availability check

The Redis connection (`redis.host`/`redis.port`) is configured in
`solr-config/bestbuy/solrconfig.xml` and supplied to the container via the
`REDIS_HOST`/`REDIS_PORT` env vars in `docker-compose.yml`.

### Building the plugin on its own

You don't need this for `make up` (the image builds it for you), but to iterate
on the Java locally:

```bash
make plugin-build  # compile + package the shaded fat JAR
make plugin-test   # run the unit tests
```

The fat JAR relocates Jedis (and commons-pool2) under
`com.solrexperiments.shaded.*` so it can't clash with anything on Solr's
classpath.

---

## Best Buy data

Product data from the [Best Buy open dataset](https://github.com/BestBuyAPIs/open-data-set)
(~52,000 products). No API key required.

```bash
make load-data                              # index the full open dataset
# or run the loader directly for a smaller / custom load:
cd data/scripts
python3 load-bestbuy-data.py --limit 500    # index the first 500 products
python3 load-bestbuy-data.py --file products.json
BESTBUY_API_KEY=yourkey python3 load-bestbuy-data.py   # pull live data via the API
```

Seed synthetic per-store availability into Redis:

```bash
make seed-redis    # 5 stores (1000-1004), ~60% in-stock over a sample SKU range
# or target specific SKUs/stores:
cd data/scripts
python3 seed-redis-bitmaps.py --stores 1000 1001 --sku-min 43000 --sku-max 200000
```

> The `seed-redis` defaults cover a sample SKU range; to see the filter actually
> drop documents, seed bits for SKUs that exist in your indexed data (e.g. take
> a few `sku` values from `make query` output and `SETBIT` them).

---

## Project structure

```
.
├── docker/
│   ├── solr/
│   │   ├── Dockerfile          ← multi-stage: builds the plugin, then the Solr image
│   │   ├── entrypoint.sh       ← starts Solr with embedded ZK, auto-creates bestbuy
│   │   └── config/             ← solr.xml, log4j2.xml
│   └── redis/
│       ├── Dockerfile
│       └── redis.conf
├── solr-redis-plugin/          ← Gradle project: PostFilter + DocTransformer
│   └── src/main/java/com/solrexperiments/redis/
│       ├── StoreAvailabilityQParserPlugin.java       ← the {!store_avail} PostFilter
│       ├── StoreAvailabilityTransformerFactory.java  ← the [store_avail] DocTransformer
│       └── RedisConnectionManager.java               ← shared Jedis pool
├── solr-config/bestbuy/        ← schema.xml, solrconfig.xml, stopwords, synonyms
├── data/scripts/               ← load-bestbuy-data.py, seed-redis-bitmaps.py
├── docker-compose.yml
└── Makefile
```

CI (`.github/workflows/build.yml`) builds/tests the plugin, then stands up the
whole stack and runs an end-to-end smoke test of both the filter and the
transformer.

---

## Troubleshooting

- **Solr container restart loops / 404 on every URL** — embedded ZooKeeper
  couldn't write its data dir. `/var/solr/data` must be owned by the `solr`
  user; a stale named volume from an older build can keep root ownership. Fix
  with a clean restart: `make down && make up` (this recreates the volume).
- **Real Solr logs** — inside the container at `/var/solr/logs/solr.log`
  (the entrypoint tails this). `make logs` shows the container/entrypoint output.
- **`make query` returns nothing for the filter** — you haven't seeded Redis
  bits for SKUs that are actually indexed. See the data section above.

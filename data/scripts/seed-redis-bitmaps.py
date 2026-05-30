#!/usr/bin/env python3
"""
Seed Redis with store-availability bitmaps for Best Buy products.

For each store, sets random availability bits for a range of product SKUs.
Bitmap key:    store:{storeId}:availability
Bit offset:    product numeric SKU
Bit value:     1 = in stock, 0 = out of stock

Usage:
    python3 seed-redis-bitmaps.py
    python3 seed-redis-bitmaps.py --redis-host localhost --redis-port 6379
"""
import argparse
import random
import sys

try:
    import redis
except ImportError:
    print("ERROR: redis package not installed. Run: pip install redis", file=sys.stderr)
    sys.exit(1)

DEFAULT_STORES = ["1000", "1001", "1002", "1003", "1004"]
SKU_MIN = 1_000_000
SKU_MAX = 1_000_500


def seed_store(r, store_id, sku_min, sku_max, in_stock_ratio=0.6):
    """Set availability bits for one store. Returns the in-stock count."""
    pipe = r.pipeline()
    count = 0
    for sku in range(sku_min, sku_max + 1):
        if random.random() < in_stock_ratio:
            pipe.setbit(f"store:{store_id}:availability", sku, 1)
            count += 1
    pipe.execute()
    return count


def main():
    ap = argparse.ArgumentParser(description="Seed Redis store-availability bitmaps")
    ap.add_argument("--redis-host", default="localhost")
    ap.add_argument("--redis-port", type=int, default=6379)
    ap.add_argument("--redis-password", default=None)
    ap.add_argument("--stores", nargs="+", default=DEFAULT_STORES)
    ap.add_argument("--sku-min", type=int, default=SKU_MIN)
    ap.add_argument("--sku-max", type=int, default=SKU_MAX)
    ap.add_argument("--in-stock-ratio", type=float, default=0.6)
    args = ap.parse_args()

    r = redis.Redis(
        host=args.redis_host,
        port=args.redis_port,
        password=args.redis_password,
        decode_responses=True,
    )
    try:
        r.ping()
    except redis.ConnectionError as e:
        print(f"ERROR: cannot connect to Redis at {args.redis_host}:{args.redis_port}: {e}",
              file=sys.stderr)
        sys.exit(1)

    print(f"Seeding {len(args.stores)} stores, SKU range {args.sku_min}-{args.sku_max}")
    total = 0
    for store_id in args.stores:
        n = seed_store(r, store_id, args.sku_min, args.sku_max, args.in_stock_ratio)
        print(f"  store:{store_id}:availability -> {n} SKUs in stock")
        total += n

    print(f"Done. {total} availability bits set across {len(args.stores)} stores.")
    print()
    print("Try the plugin (filter out-of-stock docs at store 1000):")
    print("  curl 'http://localhost:8983/solr/bestbuy/select"
          "?q=*:*&rows=5&fq={!store_avail id=1000}&fl=sku,name'")
    print()
    print("Or annotate every doc with availability:")
    print("  curl 'http://localhost:8983/solr/bestbuy/select"
          "?q=*:*&rows=5&fl=sku,name,storeAvailable:[store_avail id=1000]'")


if __name__ == "__main__":
    main()

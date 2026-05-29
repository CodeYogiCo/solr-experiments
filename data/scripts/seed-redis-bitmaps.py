#!/usr/bin/env python3
"""
Seed Redis with synthetic store availability bitmaps.

Each store has a bitmap at key: store:{storeId}:availability
Bit at offset = numeric SKU is set to 1 if product is in stock.

Usage:
  python seed-redis-bitmaps.py --redis-host localhost --redis-port 6379
  python seed-redis-bitmaps.py --solr-url http://localhost:8983/solr \
                                --collection bestbuy \
                                --num-stores 20 \
                                --availability-rate 0.7
"""

import argparse
import json
import os
import random
import sys
import time
from typing import Iterator

import redis
import requests
from tqdm import tqdm


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Seed Redis store availability bitmaps")
    p.add_argument("--redis-host",  default="localhost")
    p.add_argument("--redis-port",  type=int, default=6379)
    p.add_argument("--redis-password", default=os.getenv("REDIS_PASSWORD", "changeme"))
    p.add_argument("--solr-url",    default="http://localhost:8983/solr")
    p.add_argument("--collection",  default="bestbuy")
    p.add_argument("--num-stores",  type=int, default=20,
                   help="Number of synthetic stores to generate")
    p.add_argument("--availability-rate", type=float, default=0.7,
                   help="Probability a product is in-stock at any given store (0-1)")
    p.add_argument("--seed",        type=int, default=42,
                   help="Random seed for reproducible results")
    p.add_argument("--ttl",         type=int, default=0,
                   help="Bitmap TTL in seconds (0 = no expiry)")
    return p.parse_args()


def fetch_all_skus(solr_url: str, collection: str) -> list[int]:
    """Fetch all numeric SKUs from Solr."""
    url = f"{solr_url}/{collection}/select"
    skus: list[int] = []
    cursor = "*"
    rows = 1000

    print("Fetching SKUs from Solr…")
    while True:
        r = requests.get(url, params={
            "q": "*:*",
            "fl": "sku",
            "rows": rows,
            "sort": "id asc",
            "cursorMark": cursor,
        }, timeout=30)
        r.raise_for_status()
        data = r.json()
        docs = data["response"]["docs"]
        skus.extend(int(d["sku"]) for d in docs if "sku" in d)

        next_cursor = data.get("nextCursorMark", cursor)
        if next_cursor == cursor or not docs:
            break
        cursor = next_cursor

    print(f"Found {len(skus)} SKUs in Solr")
    return skus


def generate_store_ids(num_stores: int) -> list[str]:
    # Real Best Buy store IDs are 3-4 digit numbers
    return [str(1000 + i) for i in range(num_stores)]


def seed_store(
    r: redis.Redis,
    store_id: str,
    skus: list[int],
    availability_rate: float,
    ttl: int,
    rng: random.Random,
) -> int:
    """Write one store's availability bitmap. Returns count of available SKUs."""
    key = f"store:{store_id}:availability"
    pipe = r.pipeline(transaction=False)

    available_count = 0
    for sku in skus:
        if rng.random() < availability_rate:
            pipe.setbit(key, sku, 1)
            available_count += 1

    if ttl > 0:
        pipe.expire(key, ttl)

    pipe.execute()
    return available_count


def main() -> None:
    args = parse_args()
    rng  = random.Random(args.seed)

    # ── Connect to Redis ──────────────────────────────────────────────────────
    client = redis.Redis(
        host=args.redis_host,
        port=args.redis_port,
        password=args.redis_password or None,
        decode_responses=False,
        socket_connect_timeout=5,
    )
    try:
        client.ping()
    except redis.ConnectionError as e:
        print(f"Cannot connect to Redis at {args.redis_host}:{args.redis_port}: {e}",
              file=sys.stderr)
        sys.exit(1)

    print(f"Connected to Redis {args.redis_host}:{args.redis_port}")

    # ── Fetch SKUs from Solr ──────────────────────────────────────────────────
    skus = fetch_all_skus(args.solr_url, args.collection)
    if not skus:
        print("No SKUs found in Solr. Load product data first with load-bestbuy-data.py",
              file=sys.stderr)
        sys.exit(1)

    store_ids = generate_store_ids(args.num_stores)

    # ── Seed bitmaps ──────────────────────────────────────────────────────────
    print(f"Seeding {args.num_stores} stores × {len(skus)} SKUs "
          f"(~{args.availability_rate*100:.0f}% availability)…")

    stats: list[dict] = []
    for store_id in tqdm(store_ids, unit="store"):
        available = seed_store(
            client, store_id, skus,
            args.availability_rate, args.ttl, rng,
        )
        stats.append({"storeId": store_id, "availableSkus": available, "totalSkus": len(skus)})

    # ── Summary ───────────────────────────────────────────────────────────────
    total_available = sum(s["availableSkus"] for s in stats)
    total_slots     = args.num_stores * len(skus)
    print(f"\nDone. {total_available}/{total_slots} store-product slots marked available.")
    print(f"Example query:\n"
          f"  curl 'http://localhost:8983/solr/bestbuy/select?"
          f"q=laptop&store.id={store_ids[0]}&store.filterMode=filter&fl=sku,name,storeAvailable'")

    # Write stats to stdout as JSON for CI assertions
    json.dump(stats, sys.stdout, indent=2)


if __name__ == "__main__":
    main()

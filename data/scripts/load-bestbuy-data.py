#!/usr/bin/env python3
"""
Load Best Buy open-dataset products into Solr.

Data source: https://github.com/BestBuyAPIs/open-data-set
  - products.json  (~52K products)

Usage:
  python load-bestbuy-data.py --solr-url http://localhost:8983/solr --collection bestbuy
  python load-bestbuy-data.py --api-key YOUR_KEY   # pull live data via Best Buy API
  python load-bestbuy-data.py --file /path/to/products.json
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import requests
from tqdm import tqdm

BATCH_SIZE = 500
OPEN_DATASET_URL = (
    "https://raw.githubusercontent.com/BestBuyAPIs/open-data-set/master/products.json"
)
BESTBUY_API_BASE = "https://api.bestbuy.com/v1"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Load Best Buy data into Solr")
    p.add_argument("--solr-url",    default="http://localhost:8983/solr")
    p.add_argument("--collection",  default="bestbuy")
    p.add_argument("--file",        help="Local products.json file path")
    p.add_argument("--api-key",     default=os.getenv("BESTBUY_API_KEY"))
    p.add_argument("--limit",       type=int, default=0, help="Limit records (0=all)")
    p.add_argument("--batch-size",  type=int, default=BATCH_SIZE)
    return p.parse_args()


def fetch_open_dataset() -> list[dict]:
    print(f"Downloading open dataset from GitHub…")
    r = requests.get(OPEN_DATASET_URL, timeout=120)
    r.raise_for_status()
    return r.json()


def fetch_api(api_key: str, limit: int = 100) -> list[dict]:
    """Pull products from the Best Buy developer API (requires key)."""
    fields = (
        "sku,name,type,regularPrice,salePrice,onSale,categoryPath,"
        "manufacturer,modelNumber,shortDescription,longDescription,"
        "thumbnailImage,image,url,"
        "customerReviewAverage,customerReviewCount,"
        "onlineAvailability,inStoreAvailability,availableForInStorePickup"
    )
    url = f"{BESTBUY_API_BASE}/products"
    params = {
        "apiKey": api_key,
        "format": "json",
        "show": fields,
        "pageSize": min(limit or 100, 100),
    }
    r = requests.get(url, params=params, timeout=30)
    r.raise_for_status()
    return r.json().get("products", [])


def transform(raw: dict) -> dict | None:
    """Map raw Best Buy product dict to Solr document."""
    sku = raw.get("sku")
    if not sku:
        return None

    # Category path list (e.g. ["Electronics", "TVs", "4K TVs"])
    category_path: list[str] = []
    category_leaf: str = ""
    raw_category = raw.get("categoryPath") or raw.get("category") or []
    if isinstance(raw_category, list):
        for node in raw_category:
            if isinstance(node, dict):
                name = node.get("name", "")
            else:
                name = str(node)
            if name:
                category_path.append(name)
        category_leaf = category_path[-1] if category_path else ""
    elif isinstance(raw_category, str):
        category_leaf = raw_category
        category_path = [raw_category]

    regular_price = raw.get("regularPrice") or raw.get("price") or 0.0
    sale_price    = raw.get("salePrice") or regular_price
    on_sale       = float(sale_price) < float(regular_price)

    doc: dict[str, Any] = {
        "id":                       str(sku),
        "sku":                      int(sku),
        "name":                     raw.get("name", ""),
        "type":                     raw.get("type", ""),
        "manufacturer":             raw.get("manufacturer", ""),
        "modelNumber":              raw.get("modelNumber", ""),
        "shortDescription":         raw.get("shortDescription", ""),
        "longDescription":          raw.get("longDescription", ""),
        "regularPrice":             float(regular_price),
        "salePrice":                float(sale_price),
        "onSale":                   on_sale,
        "categoryPath":             category_path,
        "categoryLeaf":             category_leaf,
        "customerReviewAverage":    float(raw.get("customerReviewAverage") or 0),
        "customerReviewCount":      int(raw.get("customerReviewCount") or 0),
        "onlineAvailability":       bool(raw.get("onlineAvailability", False)),
        "inStoreAvailability":      bool(raw.get("inStoreAvailability", False)),
        "availableForInStorePickup":bool(raw.get("availableForInStorePickup", False)),
        "thumbnailImage":           raw.get("thumbnailImage", ""),
        "image":                    raw.get("image", ""),
        "url":                      raw.get("url", ""),
    }
    return {k: v for k, v in doc.items() if v not in (None, "", [], 0.0)}


def post_batch(session: requests.Session, update_url: str, docs: list[dict]) -> None:
    r = session.post(
        update_url,
        json=docs,
        headers={"Content-Type": "application/json"},
        timeout=60,
    )
    r.raise_for_status()


def commit(session: requests.Session, update_url: str) -> None:
    r = session.get(f"{update_url}?commit=true", timeout=30)
    r.raise_for_status()


def main() -> None:
    args = parse_args()

    # ── Fetch raw data ────────────────────────────────────────────────────────
    if args.file:
        print(f"Loading from file: {args.file}")
        with open(args.file) as f:
            raw_products = json.load(f)
    elif args.api_key:
        raw_products = fetch_api(args.api_key, args.limit or 100)
    else:
        raw_products = fetch_open_dataset()

    if args.limit:
        raw_products = raw_products[: args.limit]

    print(f"Loaded {len(raw_products)} raw products")

    # ── Transform ─────────────────────────────────────────────────────────────
    docs = [d for raw in raw_products if (d := transform(raw)) is not None]
    print(f"Transformed {len(docs)} valid documents")

    # ── Index into Solr ───────────────────────────────────────────────────────
    update_url = f"{args.solr_url}/{args.collection}/update"
    session = requests.Session()

    batches = [docs[i : i + args.batch_size] for i in range(0, len(docs), args.batch_size)]
    failed = 0
    with tqdm(total=len(docs), unit="doc", desc="Indexing") as bar:
        for batch in batches:
            try:
                post_batch(session, update_url, batch)
                bar.update(len(batch))
            except requests.HTTPError as e:
                print(f"\nBatch failed: {e}", file=sys.stderr)
                failed += len(batch)
            time.sleep(0.05)  # gentle throttle

    commit(session, update_url)
    print(f"\nDone. Indexed {len(docs) - failed}/{len(docs)} documents.")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()

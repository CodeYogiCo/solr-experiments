# Lesson 1 — Solr fundamentals

**Goal:** understand what Solr is, how this repo is wired, get product data into
the index, and run your first real queries.

**Time:** ~60–90 min · **Branch:** `lesson/01-fundamentals`

---

## 1. Concepts

### What Solr actually is

Solr is a search server built on **Lucene**. You feed it **documents** (JSON
objects — here, Best Buy products), it builds an **inverted index**, and you ask
it questions over HTTP and get ranked results back in milliseconds.

The inverted index is the core idea. A database stores rows and scans them to
find matches. Lucene flips it around: for every **term** it stores the list of
documents containing that term:

```
"laptop"  -> [doc3, doc8, doc41, ...]
"4k"      -> [doc8, doc12, ...]
```

So "find products matching laptop" is a dictionary lookup, not a table scan —
that's why search is fast, and why *how text is broken into terms* (analysis,
lesson 7) matters so much.

### Document → field → term

- A **document** is one thing you search for (one product).
- It has **fields** (`name`, `sku`, `manufacturer`, `regularPrice`, …).
- Each field has a **type** that decides how its value is processed: a `text_en`
  field gets tokenized and stemmed into many terms; a `string` field is stored
  as one exact term; numeric/date fields support range queries and sorting.
- The **schema** (`solr-config/bestbuy/schema.xml`) defines those fields and types.

### Core vs. collection

- A **core** is a single Lucene index on one node (one set of files on disk).
- A **collection** is the SolrCloud-level concept: a logical index made of one or
  more **shards**, each shard having one or more **replica cores**, coordinated by
  **ZooKeeper**. You query the *collection* and Solr fans out to the cores.

This repo runs **SolrCloud** with ZooKeeper *embedded inside the Solr process*
(`-DzkRun`) — one node, one collection called **`bestbuy`** with 1 shard / 1
replica. So here "collection" and "core" almost coincide, but you're using the
real cloud APIs you'd use in production (lesson 13 goes deep on this).

### How this repo is wired

```
docker compose up --build
        │
        ├─ solr container   :8983   ← Solr + embedded ZooKeeper (:9983 internal)
        │     • configset "bestbuy" (schema.xml + solrconfig.xml) uploaded to ZK
        │     • collection "bestbuy" auto-created on first start
        │
        └─ redis container  :6379   ← bitmaps for the store-availability plugin
```

- **Config** lives in `solr-config/bestbuy/` — `schema.xml` (fields/types) and
  `solrconfig.xml` (request handlers, caches, plugins). The entrypoint uploads it
  to ZooKeeper; the collection reads it from there.
- **Data** is loaded by `data/scripts/load-bestbuy-data.py` over HTTP — Solr is
  not pre-seeded.

---

## 2. Set up

Bring the stack up (skip if it's already running):

```bash
make up
```

Confirm Solr is alive and the collection exists:

```bash
curl -s 'http://localhost:8983/solr/admin/collections?action=LIST'
# -> {"responseHeader":{...},"collections":["bestbuy"]}
```

Open the **Admin UI** → http://localhost:8983/solr
- Left sidebar → **Collections** (or **Core Selector**) → pick `bestbuy`.
- Poke around **Query**, **Schema**, and **Files** (this is the configset from ZK).

Now load the product data:

```bash
cd data/scripts
python3 -m venv .venv && source .venv/bin/activate
pip install -q -r requirements.txt
python3 load-bestbuy-data.py            # index the full open dataset (~52k, ~1–2 min)
cd ../..
```

You should see `Done. Indexed 51646/51646 documents.`

> Tip: add `--limit 1000` for a quick partial load when you're iterating on
> config and want fast reindexes. The exercises below assume the full dataset so
> realistic queries (laptops, Samsung TVs) actually return results.

---

## 3. Anatomy of a Solr query

Everything is an HTTP GET against the `/select` handler:

```
http://localhost:8983/solr/bestbuy/select?q=*:*&rows=5
                              └ collection         │    └ how many to return
                                                   └ the query: *:* means "all docs"
```

The response has a `responseHeader` (status, timing, the params you sent) and a
`response` block with `numFound` (total matches), `start` (paging offset), and
`docs` (this page of results).

Key params you'll use constantly:

| Param | Meaning | Example |
|-------|---------|---------|
| `q`    | the query | `q=name:laptop` |
| `fq`   | filter query (narrows, doesn't score) | `fq=manufacturer:Sony` |
| `fl`   | field list to return | `fl=sku,name,regularPrice` |
| `rows` | page size | `rows=10` |
| `start`| paging offset | `start=20` |
| `sort` | ordering | `sort=regularPrice asc` |
| `wt`   | response format | `wt=json` |

---

## 4. Exercises

> Pipe through `python3 -m json.tool` for readable JSON. Try each yourself before
> peeking at the solution.

**🧪 E1 — How many products are indexed?**
Run the "all documents" query and read `numFound`.

**🧪 E2 — Keyword search.**
Find products matching the word *laptop*. (Hint: the default search field is
`name`; `q=laptop` works, or be explicit with `q=name:laptop`.)

**🧪 E3 — Return only what you need.**
Repeat E2 but return only `sku`, `name`, and `regularPrice`, 5 rows.

**🧪 E4 — Look up one product by id.**
Pick a `sku` from E3's output and fetch that single document by its `id`
(remember `id` is the unique key — here it equals the SKU as a string).

**🧪 E5 — Sort.**
Show the 5 cheapest products that match *headphones*, by `regularPrice` ascending.

**🧪 E6 — Filter vs. query.**
Find products matching *tv*, but only those made by `Samsung`, using an `fq`.
Then ask yourself: why use `fq` instead of putting `manufacturer:Samsung` in `q`?

**🧪 E7 — Read the schema.**
Without opening the file, ask Solr what type the `sku` field is, using the Schema
API. (Hint: `/solr/bestbuy/schema/fields/sku`.)

---

## 5. Solutions

**✅ E1**
```bash
curl -s 'http://localhost:8983/solr/bestbuy/select?q=*:*&rows=0' | python3 -m json.tool
```
`rows=0` because you only want the count — `numFound` should be `51646` (the
whole dataset).

**✅ E2**
```bash
curl -s 'http://localhost:8983/solr/bestbuy/select?q=laptop&rows=5&fl=name' | python3 -m json.tool
```
`q=laptop` searches the default field (`df=name`, set in `solrconfig.xml`).
`q=name:laptop` is the explicit form — same result here.

**✅ E3**
```bash
curl -s 'http://localhost:8983/solr/bestbuy/select?q=laptop&rows=5&fl=sku,name,regularPrice' | python3 -m json.tool
```

**✅ E4** (using sku 1234567 as a stand-in — use a real one from E3)
```bash
curl -s 'http://localhost:8983/solr/bestbuy/select?q=id:1234567' | python3 -m json.tool
```
`id` is the `uniqueKey` (see `schema.xml`), so this returns exactly one doc.

**✅ E5**
```bash
curl -s 'http://localhost:8983/solr/bestbuy/select?q=headphones&rows=5&sort=regularPrice+asc&fl=name,regularPrice' | python3 -m json.tool
```
`sort` takes `field direction`. Sorting needs `docValues` on the field — numeric
types have it by default in this schema (lesson 2).

**✅ E6**
```bash
curl -s 'http://localhost:8983/solr/bestbuy/select?q=tv&fq=manufacturer:Samsung&rows=5&fl=name,manufacturer' | python3 -m json.tool
```
Use `fq` because it (a) doesn't affect relevance scoring — "Samsung" shouldn't
make a doc *more relevant* to "tv", just eligible — and (b) is cached in the
filterCache and reused across queries (lesson 5). `q` is for *what you're
searching for and ranking by*; `fq` is for *narrowing the candidate set*.

**✅ E7**
```bash
curl -s 'http://localhost:8983/solr/bestbuy/schema/fields/sku' | python3 -m json.tool
# -> "type":"long", indexed/stored=true (docValues inherited from the 'long' type)
```

---

## 6. Recap

- Solr indexes **documents** of typed **fields** into an **inverted index**, and
  you query it over HTTP.
- A **collection** (SolrCloud) is made of **shards** and **replica cores**,
  coordinated by **ZooKeeper** — here, one node with embedded ZK.
- `q` searches and scores; `fq` filters without scoring; `fl` shapes the
  response; `rows`/`start` page; `sort` orders.
- Config (schema + solrconfig) lives in ZooKeeper, uploaded from
  `solr-config/bestbuy/`.

**Next:** `lesson/02-schema` — why `sku` is a `long`, what `indexed` /
`stored` / `docValues` actually do, and how to change the schema and reindex.
Say *"ready for lesson 2"* when you want it.

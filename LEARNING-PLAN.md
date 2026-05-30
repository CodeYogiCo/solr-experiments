# Learn Solr in 15 days — hands-on with a real index

A 15-day, branch-per-lesson course built on this repo's Best Buy + Redis stack.
You learn on a real ~52k-product e-commerce index, not toy data — and by the end
you've built a tuned, faceted search app with custom plugins.

## How this course is laid out

Each lesson lives on its **own branch**, chained linearly so the system grows
day by day:

```
main
 └─ lesson/01-fundamentals
     └─ lesson/02-schema
         └─ lesson/03-querying
             └─ ... up to lesson/15-capstone
```

Every lesson branch adds a `lessons/NN-topic/LESSON.md` with:
1. **Concepts** — what you need to know, grounded in this repo.
2. **Exercises** — hands-on tasks against the live stack.
3. **Solutions** — worked answers to check yourself against.

### Working through a lesson

```bash
git checkout lesson/01-fundamentals     # start here
# read lessons/01-fundamentals/LESSON.md, do the exercises
```

When you finish a lesson, the next one gets created **branching off the one you
just did**, so your earlier changes carry forward. Just say "ready for lesson 2"
and it'll appear as `lesson/02-schema`.

### Prerequisites

- Docker running. Bring the stack up once: `make up` (Solr + Redis, auto-creates
  the `bestbuy` collection). Solr UI → http://localhost:8983/solr
- That's it. No local Java/Python needed except for the data-load scripts
  (the lessons walk you through those).

## The 15 days

| Day | Branch | Focus |
|----:|--------|-------|
| 1 | `lesson/01-fundamentals` | Cores vs collections, Admin UI, index the dataset, first queries |
| 2 | `lesson/02-schema` | Field types, `indexed`/`stored`/`docValues`, copyFields, analyzers intro |
| 3 | `lesson/03-querying` | Query parsers (lucene/dismax/edismax), `q`/`fq`/`fl`/`sort`, ranges, boolean |
| 4 | `lesson/04-relevance` | BM25 scoring, `qf`/`pf`/`bf`/`boost`, `debugQuery`, reading `explain` |
| 5 | `lesson/05-filters-caching` | `fq`, filterCache, cost, `{!cache=false}`, the `NOW` gotcha |
| 6 | `lesson/06-faceting` | Field/range/query facets, the JSON Facet API, e-commerce navigation |
| 7 | `lesson/07-text-analysis` | Synonyms, stemming, n-grams, the Analysis screen, suggester/autocomplete |
| 8 | `lesson/08-indexing` | UpdateRequestProcessors, atomic/partial updates, soft vs hard commits |
| 9 | `lesson/09-function-queries` | ValueSource, `frange`, build a `trending()` function (first custom plugin) |
| 10 | `lesson/10-doctransformers` | Build a `[promo_active]` transformer (time-based field flip) |
| 11 | `lesson/11-qparser-postfilter` | Custom QParser + PostFilter (the store-availability pattern) |
| 12 | `lesson/12-searchcomponents` | first/last components, a "customers also viewed" response section |
| 13 | `lesson/13-solrcloud` | ZooKeeper, shards/replicas/leaders, Collections API, document routing |
| 14 | `lesson/14-performance-ops` | Caches, heap, commit strategy, slow-query analysis, monitoring |
| 15 | `lesson/15-capstone` | Tie it together: tuned relevance + facets + availability + promo + trending |

## Conventions used in the lessons

- `curl` examples assume the stack is up on `localhost:8983`.
- Responses are piped through `python3 -m json.tool` for readability — drop it if
  you prefer raw output.
- 🧪 marks an exercise, ✅ marks its solution.

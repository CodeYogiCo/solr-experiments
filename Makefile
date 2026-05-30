# ════════════════════════════════════════════════════════════════════════════
#  Solr-Redis local playground — Makefile
#
#  Single-node Solr with embedded ZooKeeper + Redis, all via docker compose.
#  Typical first run:
#     make up            # build images + start solr + redis (auto-creates collection)
#     make seed-redis    # seed sample store-availability bitmaps
#     make load-data     # index sample Best Buy products
#     make query         # run a sample availability-filtered query
# ════════════════════════════════════════════════════════════════════════════

SOLR_URL ?= http://localhost:8983/solr
COMPOSE  := docker compose

.DEFAULT_GOAL := help

.PHONY: help up down restart logs collection seed-redis load-data query \
        plugin-build plugin-test clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Stack lifecycle ───────────────────────────────────────────────────────────
up: ## Build images and start Solr + Redis (auto-creates the bestbuy collection)
	$(COMPOSE) up --build -d
	@echo "Waiting for Solr..."
	@until curl -sf $(SOLR_URL)/admin/info/system > /dev/null 2>&1; do sleep 3; done
	@echo ""
	@echo "Solr UI:  http://localhost:8983/solr"
	@echo "Next:     make seed-redis  &&  make load-data  &&  make query"

down: ## Stop the stack and remove volumes
	$(COMPOSE) down -v

restart: ## Restart the stack (keeps volumes)
	$(COMPOSE) restart

logs: ## Tail logs from all services
	$(COMPOSE) logs -f

# ── Collection / data ─────────────────────────────────────────────────────────
collection: ## Create the bestbuy collection (1 shard) — usually auto-created on 'up'
	curl -sf "$(SOLR_URL)/admin/collections?action=CREATE\
&name=bestbuy&numShards=1&replicationFactor=1\
&collection.configName=bestbuy" | python3 -m json.tool || true

seed-redis: ## Seed Redis with sample store-availability bitmaps
	cd data/scripts && pip install -r requirements.txt -q && \
	python3 seed-redis-bitmaps.py

load-data: ## Index sample Best Buy product data into Solr
	cd data/scripts && pip install -r requirements.txt -q && \
	python3 load-bestbuy-data.py

query: ## Run a sample store-availability query (filter + annotate)
	@echo "── Filter: only docs in stock at store 1000 ──"
	@curl -sf "$(SOLR_URL)/bestbuy/select?q=*:*&rows=3&fq=\{!store_avail%20id=1000\}&fl=sku,name" \
		| python3 -m json.tool
	@echo "── Annotate: every doc tagged with storeAvailable ──"
	@curl -sf "$(SOLR_URL)/bestbuy/select?q=*:*&rows=3&fl=sku,name,storeAvailable:\[store_avail%20id=1000\]" \
		| python3 -m json.tool

# ── Plugin (Gradle) ───────────────────────────────────────────────────────────
plugin-build: ## Compile + package the Solr Redis plugin fat JAR
	cd solr-redis-plugin && ./gradlew --no-daemon clean shadowJar

plugin-test: ## Run plugin unit tests
	cd solr-redis-plugin && ./gradlew --no-daemon test

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean: ## Stop stack, remove volumes, clean plugin build output
	$(COMPOSE) down -v --remove-orphans
	cd solr-redis-plugin && ./gradlew --no-daemon clean 2>/dev/null || true

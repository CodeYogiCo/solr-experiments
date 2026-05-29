.PHONY: help build up down logs plugin-build plugin-test data-load seed-redis \
        k8s-apply k8s-delete clean

REGISTRY   ?= ghcr.io/codeyogico/solr-experiments
TAG        ?= latest
COMPOSE    ?= docker compose
SOLR_URL   ?= http://localhost:8983/solr
REDIS_HOST ?= localhost
REDIS_PORT ?= 6379

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Local dev ──────────────────────────────────────────────────────────────────
build: plugin-build ## Build all Docker images
	$(COMPOSE) build

up: ## Start full stack locally
	$(COMPOSE) up -d
	@echo "Waiting for Solr to be ready..."
	@until curl -sf $(SOLR_URL)/admin/info/system > /dev/null; do sleep 3; done
	@echo "Solr is up: $(SOLR_URL)"

down: ## Stop all containers
	$(COMPOSE) down -v

logs: ## Tail all container logs
	$(COMPOSE) logs -f

solr-logs: ## Tail Solr logs only
	$(COMPOSE) logs -f solr1

# ── Plugin ────────────────────────────────────────────────────────────────────
plugin-build: ## Compile and package the Solr Redis plugin
	cd solr-redis-plugin && mvn package -DskipTests -q

plugin-test: ## Run plugin unit tests
	cd solr-redis-plugin && mvn test

plugin-install: plugin-build ## Copy plugin JAR into the Solr image lib directory
	cp solr-redis-plugin/target/solr-redis-plugin-*.jar docker/solr/lib/

# ── Data ──────────────────────────────────────────────────────────────────────
collection-create: ## Create the bestbuy Solr collection
	curl -sf "$(SOLR_URL)/admin/collections?action=CREATE&name=bestbuy&numShards=2&replicationFactor=2&maxShardsPerNode=2&collection.configName=bestbuy" | python3 -m json.tool

data-load: ## Load Best Buy product data into Solr
	cd data/scripts && pip install -r requirements.txt -q && \
	python3 load-bestbuy-data.py --solr-url $(SOLR_URL) --collection bestbuy

seed-redis: ## Seed Redis bitmaps with synthetic store availability
	cd data/scripts && python3 seed-redis-bitmaps.py \
	  --redis-host $(REDIS_HOST) --redis-port $(REDIS_PORT)

# ── Image publishing ───────────────────────────────────────────────────────────
push: ## Push images to registry
	docker push $(REGISTRY)/solr:$(TAG)
	docker push $(REGISTRY)/zookeeper:$(TAG)
	docker push $(REGISTRY)/redis:$(TAG)

# ── Kubernetes ────────────────────────────────────────────────────────────────
k8s-apply: ## Apply all Kubernetes manifests
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/zookeeper/
	kubectl apply -f k8s/redis/
	@echo "Waiting for ZooKeeper..."
	kubectl rollout status statefulset/zookeeper -n solr-stack --timeout=120s
	kubectl apply -f k8s/solr/

k8s-delete: ## Tear down Kubernetes stack
	kubectl delete -f k8s/ --ignore-not-found

k8s-status: ## Show pod status in solr-stack namespace
	kubectl get pods -n solr-stack -o wide

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean: ## Remove build artifacts and volumes
	$(COMPOSE) down -v --remove-orphans
	cd solr-redis-plugin && mvn clean -q
	rm -f docker/solr/lib/solr-redis-plugin-*.jar

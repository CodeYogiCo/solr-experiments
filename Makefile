.PHONY: help dev dev-down dev-collection dev-load \
        zk-up zk-down node-add node-remove node-restart \
        cluster-status collection-create data-load seed-redis \
        plugin-build plugin-test plugin-install \
        build push k8s-apply k8s-delete clean

REGISTRY   ?= ghcr.io/codeyogico/solr-experiments
TAG        ?= latest
SOLR_URL   ?= http://localhost:8983/solr
REDIS_HOST ?= localhost
REDIS_PORT ?= 6379

# NODE must be set for node-* targets  (e.g. make node-add NODE=3)
NODE ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ══════════════════════════════════════════════════════════════════════════════
# EXPERIMENTATION MODE  –  single Solr node, ZooKeeper embedded inside Solr
# ══════════════════════════════════════════════════════════════════════════════

dev: ## Start experimentation stack (embedded ZK, 1 Solr node + Redis)
	docker compose -f docker-compose.dev.yml up -d --build
	@echo "Waiting for Solr..."
	@until curl -sf http://localhost:8983/solr/admin/info/system > /dev/null 2>&1; do sleep 3; done
	@echo ""
	@echo "Solr UI:  http://localhost:8983/solr"
	@echo ""
	@echo "Next: make dev-collection  →  create bestbuy collection"
	@echo "      make dev-load        →  index Best Buy products"

dev-down: ## Stop experimentation stack
	docker compose -f docker-compose.dev.yml down -v

dev-collection: ## Create bestbuy collection (embedded ZK, 1 shard)
	curl -sf "$(SOLR_URL)/admin/collections?action=CREATE\
&name=bestbuy&numShards=1&replicationFactor=1\
&collection.configName=bestbuy" | python3 -m json.tool

dev-load: ## Load Best Buy data into experimentation stack
	cd data/scripts && pip install -r requirements.txt -q && \
	python3 load-bestbuy-data.py --solr-url $(SOLR_URL) --collection bestbuy --limit 5000

# ══════════════════════════════════════════════════════════════════════════════
# PRODUCTION MODE  –  separate ZK cluster (3 nodes) + Solr cluster + HAProxy LB
# ══════════════════════════════════════════════════════════════════════════════

# ── ZooKeeper (always-on backbone) ───────────────────────────────────────────
zk-up: ## Start the 3-node ZooKeeper ensemble + Redis (no Solr)
	docker compose up -d zookeeper1 zookeeper2 zookeeper3 redis
	@echo "Waiting for ZooKeeper quorum..."
	@until echo ruok | nc -w 2 localhost 2181 | grep -q imok; do sleep 2; done
	@echo "ZooKeeper is ready."

zk-down: ## Stop ZooKeeper + Redis (also stops all Solr nodes)
	docker compose down

# ── Solr node management ─────────────────────────────────────────────────────
# Each Solr container is independent. ZooKeeper handles leader election.
# You decide how many nodes run and when.

node-add: ## Add a Solr node  →  make node-add NODE=3
	@[ -n "$(NODE)" ] || { echo "Usage: make node-add NODE=<number>"; exit 1; }
	@bash scripts/node-add.sh $(NODE)

node-remove: ## Gracefully remove a Solr node  →  make node-remove NODE=3
	@[ -n "$(NODE)" ] || { echo "Usage: make node-remove NODE=<number>"; exit 1; }
	@bash scripts/node-remove.sh $(NODE)

node-remove-purge: ## Remove node AND delete its data volume  →  make node-remove-purge NODE=3
	@[ -n "$(NODE)" ] || { echo "Usage: make node-remove-purge NODE=<number>"; exit 1; }
	@bash scripts/node-remove.sh $(NODE) --purge

node-restart: ## Restart a single Solr node  →  make node-restart NODE=2
	@[ -n "$(NODE)" ] || { echo "Usage: make node-restart NODE=<number>"; exit 1; }
	docker compose --profile solr-node-$(NODE) restart solr-node-$(NODE)

cluster-status: ## Show live nodes, shard leaders, ZK health
	@bash scripts/cluster-status.sh $(SOLR_URL)

node-logs: ## Tail logs for one node  →  make node-logs NODE=1
	@[ -n "$(NODE)" ] || { echo "Usage: make node-logs NODE=<number>"; exit 1; }
	docker compose --profile solr-node-$(NODE) logs -f solr-node-$(NODE)

# ── Quick start (ZK + first 2 nodes) ─────────────────────────────────────────
up: zk-up ## Start ZooKeeper + 2 Solr nodes (minimum viable cluster)
	$(MAKE) node-add NODE=1
	$(MAKE) node-add NODE=2
	@echo ""
	@echo "Cluster is up. Solr UI: http://localhost:8983/solr"
	@echo ""
	@echo "Next steps:"
	@echo "  make collection-create   – create the bestbuy collection"
	@echo "  make data-load           – index Best Buy product data"
	@echo "  make seed-redis          – seed store availability bitmaps"
	@echo "  make node-add NODE=3     – add a third Solr node"

down: ## Stop everything
	docker compose down

# ── Plugin ────────────────────────────────────────────────────────────────────
plugin-build: ## Compile and package the Solr Redis plugin JAR
	cd solr-redis-plugin && mvn package -DskipTests -q

plugin-test: ## Run plugin unit tests
	cd solr-redis-plugin && mvn test

plugin-install: plugin-build ## Copy plugin JAR into docker/solr/lib/
	mkdir -p docker/solr/lib
	cp solr-redis-plugin/target/solr-redis-plugin-*.jar docker/solr/lib/

# ── Collection management ────────────────────────────────────────────────────
collection-create: ## Create the bestbuy Solr collection (2 shards, RF=2)
	curl -sf "$(SOLR_URL)/admin/collections?action=CREATE\
&name=bestbuy\
&numShards=2\
&replicationFactor=2\
&maxShardsPerNode=2\
&collection.configName=bestbuy" | python3 -m json.tool

# ── Data loading ─────────────────────────────────────────────────────────────
data-load: ## Index Best Buy product data into Solr
	cd data/scripts && pip install -r requirements.txt -q && \
	python3 load-bestbuy-data.py --solr-url $(SOLR_URL) --collection bestbuy

seed-redis: ## Seed Redis bitmaps with synthetic store availability
	cd data/scripts && python3 seed-redis-bitmaps.py \
	  --redis-host $(REDIS_HOST) --redis-port $(REDIS_PORT)

# ── Build ─────────────────────────────────────────────────────────────────────
build: plugin-install ## Build all Docker images (plugin must be compiled first)
	docker compose build

push: ## Push images to registry
	docker push $(REGISTRY)/solr:$(TAG)
	docker push $(REGISTRY)/zookeeper:$(TAG)
	docker push $(REGISTRY)/redis:$(TAG)

# ── Kubernetes ───────────────────────────────────────────────────────────────
k8s-apply: ## Apply all Kubernetes manifests
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/zookeeper/
	kubectl apply -f k8s/redis/
	kubectl rollout status statefulset/zookeeper -n solr-stack --timeout=120s
	kubectl apply -f k8s/solr/

k8s-delete: ## Tear down Kubernetes stack
	kubectl delete -f k8s/ --ignore-not-found

# ── Terraform EC2 bare metal ──────────────────────────────────────────────────
ec2-plan: ## Plan EC2 bare-metal infrastructure changes
	cd infra/terraform/aws-ec2 && terraform init && terraform plan

# ── Cloud deploy (unified – all clouds use the same interface) ───────────────
# Usage: make cloud-apply CLOUD=gcp   or  make cloud-apply CLOUD=aws  etc.

cloud-plan: ## Show Terraform plan  →  make cloud-plan CLOUD=gcp
	@[ -n "$(CLOUD)" ] || { echo "Usage: make cloud-plan CLOUD=<aws|gcp|azure>"; exit 1; }
	bash infra/provision.sh $(CLOUD) plan

cloud-apply: ## Provision infra + deploy  →  make cloud-apply CLOUD=gcp TAG=v1.0
	@[ -n "$(CLOUD)" ] || { echo "Usage: make cloud-apply CLOUD=<aws|gcp|azure>"; exit 1; }
	bash infra/provision.sh $(CLOUD) apply --tag $(TAG) --nodes $(NODES) --install

cloud-deploy: ## Deploy new images to existing VMs  →  make cloud-deploy CLOUD=aws TAG=v1.2
	@[ -n "$(CLOUD)" ] || { echo "Usage: make cloud-deploy CLOUD=<aws|gcp|azure>"; exit 1; }
	bash infra/provision.sh $(CLOUD) deploy-only --tag $(TAG) --update

cloud-destroy: ## DESTROY cloud infrastructure (irreversible!)  →  make cloud-destroy CLOUD=gcp
	@[ -n "$(CLOUD)" ] || { echo "Usage: make cloud-destroy CLOUD=<aws|gcp|azure>"; exit 1; }
	bash infra/provision.sh $(CLOUD) destroy

# Legacy AWS-specific aliases (kept for backwards compatibility)
ec2-plan:    cloud-plan    CLOUD=aws
ec2-apply:   cloud-apply   CLOUD=aws
ec2-deploy:  cloud-deploy  CLOUD=aws
ec2-destroy: cloud-destroy CLOUD=aws

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean: ## Remove containers, volumes, and build artifacts
	docker compose down -v --remove-orphans
	cd solr-redis-plugin && mvn clean -q 2>/dev/null || true
	rm -f docker/solr/lib/solr-redis-plugin-*.jar

# Solr + ZooKeeper Production Stack

Production-grade SolrCloud with a Best Buy e-commerce dataset and a Redis
bitmap plugin for real-time store availability filtering.

---

## Two deployment modes

### Mode 1 — Experimentation (embedded ZooKeeper)

One container. ZooKeeper runs inside the Solr process.
Use this for local development, schema iteration, and feature testing.

```
┌──────────────────────────────┐
│  solr-dev container          │
│  ├── Solr  :8983             │
│  └── ZooKeeper (embedded)    │   + Redis container
│       :9983 (internal)       │
└──────────────────────────────┘
```

```bash
make dev               # start (builds images if needed)
make dev-collection    # create the bestbuy collection
make dev-load          # index ~5 000 Best Buy products
make dev-down          # stop and remove volumes
```

Solr UI → http://localhost:8983/solr

---

### Mode 2 — Production (separate ZooKeeper cluster)

Three ZooKeeper nodes in their own cluster, behind an HAProxy TCP load
balancer. Solr nodes connect to one address (`zookeeper-lb:2181`) and
are added or removed manually. ZooKeeper handles shard leader election
automatically.

```
  ┌─────────────────────────────────────────────────┐
  │  ZooKeeper Ensemble (3 nodes)                   │
  │  zookeeper1  zookeeper2  zookeeper3             │
  └───────────────────┬─────────────────────────────┘
                      │ health-checked by HAProxy
              ┌───────▼────────┐
              │ zookeeper-lb   │  :2181  (single address for Solr)
              │ (HAProxy L4)   │  :8404  stats UI
              └───────┬────────┘
        ┌─────────────┼─────────────┐
        ▼             ▼             ▼
  solr-node-1   solr-node-2   solr-node-N
  :8983         :8984         :898N
```

```bash
make up                 # start ZooKeeper + HAProxy + 2 Solr nodes
make cluster-status     # show live nodes and shard leaders
make node-add NODE=3    # add a third Solr node
make node-remove NODE=2 # remove a node (ZK auto-elects new leader)
make collection-create  # create bestbuy collection (2 shards, RF=2)
make data-load          # index Best Buy products
make seed-redis         # seed store availability bitmaps
make down               # stop everything
```

---

## Components

| Component | Image | Purpose |
|---|---|---|
| Solr | `docker/solr/` | Search engine, SolrCloud mode |
| ZooKeeper | `docker/zookeeper/` | Leader election, cluster state, config storage |
| HAProxy | `haproxy:2.9-alpine` | L4 TCP load balancer for ZK client port |
| Redis | `docker/redis/` | Bitmap store availability data |

---

## Solr Redis plugin

A custom Java `SearchComponent` (`solr-redis-plugin/`) that checks Redis
bitmaps at query time to filter or annotate results by store availability.

**How bitmaps work:**
- Key: `store:{storeId}:availability`
- Bit offset: numeric product SKU
- `SETBIT store:1234:availability 7823109 1` → product 7823109 is in stock at store 1234
- `GETBIT store:1234:availability 7823109` → O(1) availability check

**Query parameters:**

| Parameter | Default | Description |
|---|---|---|
| `store.id` | (none) | Store ID to check. Omit to skip availability filtering. |
| `store.productIdField` | `sku` | Solr field holding the numeric SKU |
| `store.filterMode` | `filter` | `filter` removes unavailable docs; `annotate` adds `storeAvailable` field |

**Example:**
```
GET /solr/bestbuy/select?q=laptop&store.id=1234&store.filterMode=filter&fl=sku,name
```

Build and install the plugin:
```bash
make plugin-build    # compiles, runs tests, creates fat JAR
make plugin-install  # copies JAR to docker/solr/lib/
make build           # rebuilds the Solr Docker image with the new JAR
```

---

## Best Buy data

Product data from the [Best Buy open dataset](https://github.com/BestBuyAPIs/open-data-set)
(~52 000 products). A Best Buy developer API key is optional for live data.

```bash
# Load from open dataset (no API key needed)
make data-load

# Load from live API
BESTBUY_API_KEY=yourkey make data-load

# Seed synthetic store availability in Redis
make seed-redis   # generates 20 stores, ~70% availability rate
```

---

## Cloud deployment

### AWS EC2 bare metal (plain Docker Compose, no orchestrator)

```bash
cd infra/terraform/aws-ec2
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init && terraform apply              # provisions VMs, NLB, EFS

# Roll out a new image version
bash deploy.sh v1.2.3
```

Terraform creates:
- 3 EC2 instances (Solr + ZooKeeper co-located, one per AZ)
- 1 EC2 instance (Redis)
- AWS Network Load Balancer in front of ZooKeeper (Solr uses NLB DNS, no IPs)
- EFS filesystem for persistent data (survives instance replacement)
- ALB for public Solr access

### Kubernetes (any cloud — EKS, GKE, AKS, or self-hosted)

```bash
make k8s-apply    # creates namespace, ZK StatefulSet, Redis, Solr StatefulSet
make k8s-status   # show pod status
make k8s-delete   # tear down
```

### Any cloud VM (SSH deploy)

```bash
# First deploy (installs Docker, starts ZK + 2 Solr nodes)
./scripts/deploy-to-vm.sh <VM_IP> --install --nodes 1,2

# Add a node to a running cluster
./scripts/deploy-to-vm.sh <VM_IP> --nodes 3

# Rolling image update
./scripts/deploy-to-vm.sh <VM_IP> --tag v1.2.3 --update
```

Works on: AWS EC2, GCP Compute Engine, Azure VM, DigitalOcean, Hetzner, Linode.

### GitHub Actions (automated)

Set in your repo **Settings → Secrets and Variables**:

| Type | Name | Value |
|---|---|---|
| Secret | `VM_SSH_PRIVATE_KEY` | SSH private key |
| Secret | `REDIS_PASSWORD` | Redis password |
| Variable | `VM_HOST` | VM public IP |
| Variable | `VM_USER` | `ubuntu` |

Then: **Actions → Deploy to Cloud VM → Run workflow**

Options: `full-deploy` / `update-images` / `add-node` / `remove-node`

---

## ZooKeeper load balancer — why L4 only

The HAProxy and AWS NLB configs use **TCP (L4)** load balancing, not HTTP (L7).
ZooKeeper speaks a binary protocol; HTTP load balancers cannot handle it.

The peer ports (2888/3888) used for ZK leader election are **never** behind
the load balancer — ZK nodes communicate directly with each other on the
Docker/VPC network. Only the client port (2181) is proxied.

---

## Manual node scaling (production mode)

Nodes are managed explicitly — no auto-scaling.

```bash
make node-add NODE=4        # start solr-node-4
make node-remove NODE=2     # graceful remove (ZK elects new leaders)
make node-remove-purge NODE=2  # remove + delete data volume
make node-logs NODE=1       # tail logs for node 1
make cluster-status         # live view of all nodes and shard leaders
```

When a node is removed, ZooKeeper detects the departure in < 5 seconds and
promotes a replica to leader for any shards that lost theirs. No manual
intervention required.

---

## Project structure

```
.
├── docker/
│   ├── solr/
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh       ← handles embedded + production modes
│   │   └── config/             ← solr.xml, log4j2.xml
│   ├── zookeeper/
│   │   ├── Dockerfile
│   │   └── entrypoint.sh       ← self-registers with Consul if present
│   ├── redis/
│   │   ├── Dockerfile
│   │   └── redis.conf
│   └── haproxy/
│       └── haproxy.cfg         ← TCP LB for ZK client port
├── solr-redis-plugin/          ← Java Maven project (Solr SearchComponent)
├── solr-config/bestbuy/        ← schema.xml, solrconfig.xml, synonyms
├── data/scripts/               ← Python: data loader + Redis bitmap seeder
├── infra/
│   ├── terraform/aws-ec2/      ← EC2 bare-metal Terraform
│   └── swarm/                  ← Docker Swarm stack file
├── k8s/                        ← Kubernetes manifests
├── scripts/                    ← node-add, node-remove, cluster-status, deploy-to-vm
├── docker-compose.yml          ← PRODUCTION mode
├── docker-compose.dev.yml      ← EXPERIMENTATION mode (embedded ZK)
└── Makefile
```

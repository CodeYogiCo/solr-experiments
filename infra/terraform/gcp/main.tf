################################################################################
# GCP deployment – Solr + ZooKeeper + Redis on Compute Engine
#
# Creates:
#   - VPC + subnet
#   - Firewall rules (SSH from admin, Solr/ZK/Redis internal)
#   - 3 Compute Engine instances (Solr + ZooKeeper co-located)
#   - 1 Compute Engine instance (Redis)
#   - Filestore NFS for persistent data (survives instance deletion)
#   - Internal TCP Load Balancer for ZooKeeper (single address for Solr)
#   - External TCP Load Balancer for Solr (public access)
#   - Startup script bootstraps Docker + Docker Compose on first boot
#
# Usage:
#   gcloud auth application-default login
#   terraform init
#   terraform apply -var-file=terraform.tfvars
################################################################################

terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ── Data ────────────────────────────────────────────────────────────────────────
data "google_compute_zones" "available" {
  region = var.region
}

# ── VPC ──────────────────────────────────────────────────────────────────────────
resource "google_compute_network" "main" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "${var.name}-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.main.id
}

# ── Firewall rules ───────────────────────────────────────────────────────────────
resource "google_compute_firewall" "ssh" {
  name    = "${var.name}-allow-ssh"
  network = google_compute_network.main.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = [var.admin_cidr]
  target_tags   = ["solr-stack"]
}

resource "google_compute_firewall" "solr_public" {
  name    = "${var.name}-allow-solr-public"
  network = google_compute_network.main.name
  allow {
    protocol = "tcp"
    ports    = ["8983"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["solr-node"]
}

resource "google_compute_firewall" "internal" {
  name    = "${var.name}-allow-internal"
  network = google_compute_network.main.name
  allow {
    protocol = "tcp"
    ports    = ["2181", "2888", "3888", "6379", "8983"]
  }
  source_tags = ["solr-stack"]
  target_tags = ["solr-stack"]
}

resource "google_compute_firewall" "health_check" {
  name    = "${var.name}-allow-health-check"
  network = google_compute_network.main.name
  allow {
    protocol = "tcp"
  }
  # GCP health check probe ranges
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["solr-stack"]
}

resource "google_compute_firewall" "nfs" {
  name    = "${var.name}-allow-nfs"
  network = google_compute_network.main.name
  allow {
    protocol = "tcp"
    ports    = ["2049"]
  }
  source_tags = ["solr-stack"]
  target_tags = ["filestore"]
}

# ── SSH key ───────────────────────────────────────────────────────────────────────
resource "google_compute_project_metadata_item" "ssh_key" {
  key   = "ssh-keys"
  value = "${var.ssh_user}:${var.ssh_public_key}"
}

# ── Filestore (NFS) for persistent data ──────────────────────────────────────────
resource "google_filestore_instance" "solr" {
  name     = "${var.name}-filestore"
  location = data.google_compute_zones.available.names[0]
  tier     = "BASIC_HDD"

  file_shares {
    capacity_gb = 1024
    name        = "solrdata"
  }

  networks {
    network      = google_compute_network.main.name
    modes        = ["MODE_IPV4"]
    connect_mode = "DIRECT_PEERING"
  }
}

locals {
  nfs_ip   = google_filestore_instance.solr.networks[0].ip_addresses[0]
  nfs_path = "/solrdata"
}

# ── Startup script ────────────────────────────────────────────────────────────────
locals {
  startup_script = templatefile("${path.module}/startup.sh", {
    registry       = var.registry
    image_repo     = var.image_repo
    image_tag      = var.image_tag
    nfs_ip         = local.nfs_ip
    nfs_path       = local.nfs_path
    redis_internal = google_compute_instance.redis.network_interface[0].network_ip
    zk_lb_ip       = google_compute_forwarding_rule.zookeeper_ilb.ip_address
  })
}

# ── Compute Engine instances – Solr + ZooKeeper ───────────────────────────────────
resource "google_compute_instance" "solr_zk" {
  count        = 3
  name         = "${var.name}-node-${count.index + 1}"
  machine_type = var.solr_machine_type
  zone         = data.google_compute_zones.available.names[count.index % length(data.google_compute_zones.available.names)]
  tags         = ["solr-stack", "solr-node"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = 30
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    access_config {}  # gives a public IP
  }

  metadata = {
    ssh-keys       = "${var.ssh_user}:${var.ssh_public_key}"
    startup-script = templatefile("${path.module}/startup.sh", {
      zoo_my_id      = count.index + 1
      registry       = var.registry
      image_repo     = var.image_repo
      image_tag      = var.image_tag
      nfs_ip         = local.nfs_ip
      nfs_path       = local.nfs_path
      redis_internal = google_compute_instance.redis.network_interface[0].network_ip
      # ZK LB IP known after apply; startup waits for it
      zk_lb_ip       = google_compute_forwarding_rule.zookeeper_ilb.ip_address
    })
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}

# ── Compute Engine instance – Redis ──────────────────────────────────────────────
resource "google_compute_instance" "redis" {
  name         = "${var.name}-redis"
  machine_type = var.redis_machine_type
  zone         = data.google_compute_zones.available.names[0]
  tags         = ["solr-stack"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = 20
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    access_config {}
  }

  metadata = {
    ssh-keys       = "${var.ssh_user}:${var.ssh_public_key}"
    startup-script = templatefile("${path.module}/startup-redis.sh", {
      registry   = var.registry
      image_repo = var.image_repo
      image_tag  = var.image_tag
      nfs_ip     = local.nfs_ip
      nfs_path   = local.nfs_path
    })
  }
}

# ── Instance groups for load balancers ───────────────────────────────────────────
resource "google_compute_instance_group" "solr_zk" {
  count = 3
  name  = "${var.name}-ig-${count.index + 1}"
  zone  = data.google_compute_zones.available.names[count.index % length(data.google_compute_zones.available.names)]
  instances = [google_compute_instance.solr_zk[count.index].self_link]

  named_port { name = "zkclient"; port = 2181 }
  named_port { name = "solr";     port = 8983 }
}

# ── ZooKeeper internal TCP load balancer ─────────────────────────────────────────
resource "google_compute_health_check" "zookeeper" {
  name = "${var.name}-zk-hc"
  tcp_health_check { port = 2181 }
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_region_backend_service" "zookeeper" {
  name                  = "${var.name}-zk-backend"
  region                = var.region
  protocol              = "TCP"
  load_balancing_scheme = "INTERNAL"
  health_checks         = [google_compute_health_check.zookeeper.id]

  dynamic "backend" {
    for_each = google_compute_instance_group.solr_zk
    content {
      group = backend.value.self_link
    }
  }
}

resource "google_compute_forwarding_rule" "zookeeper_ilb" {
  name                  = "${var.name}-zk-ilb"
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.zookeeper.id
  ports                 = ["2181"]
  network               = google_compute_network.main.id
  subnetwork            = google_compute_subnetwork.main.id
  allow_global_access   = false
}

# ── Solr external TCP load balancer ──────────────────────────────────────────────
resource "google_compute_health_check" "solr" {
  name = "${var.name}-solr-hc"
  http_health_check {
    port         = 8983
    request_path = "/solr/admin/info/system"
  }
  check_interval_sec  = 15
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_region_backend_service" "solr" {
  name                  = "${var.name}-solr-backend"
  region                = var.region
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  health_checks         = [google_compute_health_check.solr.id]

  dynamic "backend" {
    for_each = google_compute_instance_group.solr_zk
    content {
      group = backend.value.self_link
    }
  }
}

resource "google_compute_forwarding_rule" "solr_lb" {
  name                  = "${var.name}-solr-lb"
  region                = var.region
  load_balancing_scheme = "EXTERNAL_MANAGED"
  target                = google_compute_region_target_http_proxy.solr.id
  port_range            = "80"
}

resource "google_compute_region_target_http_proxy" "solr" {
  name    = "${var.name}-solr-proxy"
  region  = var.region
  url_map = google_compute_region_url_map.solr.id
}

resource "google_compute_region_url_map" "solr" {
  name            = "${var.name}-solr-urlmap"
  region          = var.region
  default_service = google_compute_region_backend_service.solr.id
}

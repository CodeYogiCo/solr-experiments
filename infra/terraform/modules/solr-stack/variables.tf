# ── Standard input interface – every cloud implementation must accept these ───

variable "name"               { description = "Stack name prefix" }
variable "region"             { description = "Cloud region" }
variable "ssh_public_key"     { description = "SSH public key content" }
variable "admin_cidr"         { description = "CIDR allowed to SSH (e.g. 1.2.3.4/32)" }
variable "solr_instance_type" { description = "Instance size for Solr+ZK nodes" }
variable "redis_instance_type"{ description = "Instance size for Redis node" }
variable "image_tag"          { default = "latest" }
variable "image_repo"         { default = "codeyogico/solr-experiments" }
variable "registry"           { default = "ghcr.io" }
variable "zk_node_count"      { default = 3 }

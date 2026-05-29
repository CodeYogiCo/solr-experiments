# ── Standard output interface – every cloud implementation must produce these ─
# After any cloud's `terraform apply`, the deploy script reads these same keys.

output "solr_node_ips" {
  description = "Public IPs of Solr+ZK nodes (SSH targets)"
  value       = var.solr_node_ips
}

output "redis_ip" {
  description = "Public IP of the Redis node"
  value       = var.redis_ip
}

output "zk_lb_address" {
  description = "ZooKeeper load balancer address (host:2181) – set as ZK_HOST"
  value       = var.zk_lb_address
}

output "solr_lb_url" {
  description = "Public Solr endpoint"
  value       = var.solr_lb_url
}

# Cloud implementations pass these values through via these input vars
variable "solr_node_ips" {}
variable "redis_ip"      {}
variable "zk_lb_address" {}
variable "solr_lb_url"   {}

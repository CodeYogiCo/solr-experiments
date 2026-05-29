output "solr_node_ips" {
  description = "Public IPs of Solr+ZK nodes"
  value       = google_compute_instance.solr_zk[*].network_interface[0].access_config[0].nat_ip
}

output "redis_ip" {
  description = "Public IP of Redis node"
  value       = google_compute_instance.redis.network_interface[0].access_config[0].nat_ip
}

output "zk_lb_address" {
  description = "ZooKeeper internal LB address – set ZK_HOST=<this>:2181"
  value       = "${google_compute_forwarding_rule.zookeeper_ilb.ip_address}:2181"
}

output "solr_lb_url" {
  description = "Public Solr endpoint"
  value       = "http://${google_compute_forwarding_rule.solr_lb.ip_address}/solr"
}

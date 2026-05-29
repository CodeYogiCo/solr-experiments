output "solr_node_ips" {
  value = azurerm_public_ip.solr_zk[*].ip_address
}
output "redis_ip" {
  value = azurerm_public_ip.redis.ip_address
}
output "zk_lb_address" {
  value = "${azurerm_lb.zookeeper.frontend_ip_configuration[0].private_ip_address}:2181"
}
output "solr_lb_url" {
  value = "http://${azurerm_public_ip.solr_zk[0].ip_address}:8983/solr"
}

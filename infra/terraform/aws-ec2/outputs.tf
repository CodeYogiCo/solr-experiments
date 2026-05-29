output "alb_dns_name" {
  description = "Public Solr endpoint"
  value       = "http://${aws_lb.solr.dns_name}/solr"
}

output "node_public_ips" {
  description = "SSH IPs for the 3 Solr+ZK nodes"
  value       = aws_instance.solr_zk[*].public_ip
}

output "redis_public_ip" {
  description = "SSH IP for the Redis node"
  value       = aws_instance.redis.public_ip
}

output "efs_id" {
  description = "EFS filesystem ID"
  value       = aws_efs_file_system.solr.id
}

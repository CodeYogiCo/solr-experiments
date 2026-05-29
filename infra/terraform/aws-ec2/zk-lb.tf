################################################################################
# AWS Network Load Balancer for ZooKeeper client port (2181)
#
# Solr nodes only need: ZK_HOST=<nlb_dns_name>:2181
# NLB health-checks each ZK EC2 instance and routes only to healthy ones.
# The 2888/3888 peer ports are NOT behind this LB.
################################################################################

# ── NLB ──────────────────────────────────────────────────────────────────────
resource "aws_lb" "zookeeper" {
  name               = "${var.name}-zk-nlb"
  internal           = true   # only reachable from within the VPC
  load_balancer_type = "network"
  subnets            = aws_subnet.private[*].id
  tags               = { Name = "${var.name}-zk-nlb" }
}

# ── Target group ─────────────────────────────────────────────────────────────
resource "aws_lb_target_group" "zookeeper" {
  name        = "${var.name}-zk-tg"
  port        = 2181
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = 2181
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "${var.name}-zk-tg" }
}

resource "aws_lb_target_group_attachment" "zookeeper" {
  count            = 3
  target_group_arn = aws_lb_target_group.zookeeper.arn
  target_id        = aws_instance.solr_zk[count.index].id
  port             = 2181
}

# ── Listener ─────────────────────────────────────────────────────────────────
resource "aws_lb_listener" "zookeeper" {
  load_balancer_arn = aws_lb.zookeeper.arn
  port              = 2181
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.zookeeper.arn
  }
}

# ── Output the NLB DNS name ───────────────────────────────────────────────────
# Solr nodes are configured with: ZK_HOST=<zk_lb_dns>:2181
output "zk_lb_dns" {
  description = "ZooKeeper NLB DNS – set ZK_HOST=<this>:2181 on all Solr nodes"
  value       = aws_lb.zookeeper.dns_name
}

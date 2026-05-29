################################################################################
# AWS EC2 bare-metal deployment – Solr + ZooKeeper + Redis
#
# Creates:
#   - VPC with public + private subnets across 3 AZs
#   - 3 EC2 instances: one per ZooKeeper + co-located Solr node
#   - 1 EC2 instance: Redis
#   - EFS filesystem for persistent Solr/ZK data (survives instance replacement)
#   - ALB for public Solr access
#   - Security groups with least-privilege rules
#   - User data that bootstraps Docker + Docker Compose on first boot
#
# Usage:
#   terraform init
#   terraform plan  -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
################################################################################

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to store state in S3
  # backend "s3" {
  #   bucket = "my-terraform-state"
  #   key    = "solr-stack/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

# ── Data ────────────────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" { state = "available" }

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ── VPC ─────────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 3)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.name}-private-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security groups ──────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "ALB – allow public HTTP/HTTPS"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name}-alb-sg" }
}

resource "aws_security_group" "solr" {
  name        = "${var.name}-solr"
  description = "Solr nodes"
  vpc_id      = aws_vpc.main.id

  # Solr UI from ALB only
  ingress {
    from_port       = 8983
    to_port         = 8983
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  # Inter-node replication
  ingress {
    from_port = 8983
    to_port   = 8983
    protocol  = "tcp"
    self      = true
  }
  # SSH from admin CIDR
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name}-solr-sg" }
}

resource "aws_security_group" "zookeeper" {
  name        = "${var.name}-zookeeper"
  description = "ZooKeeper ensemble"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 2181
    to_port         = 2181
    protocol        = "tcp"
    security_groups = [aws_security_group.solr.id]
  }
  ingress {
    from_port = 2181
    to_port   = 3888
    protocol  = "tcp"
    self      = true
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name}-zk-sg" }
}

resource "aws_security_group" "redis" {
  name        = "${var.name}-redis"
  description = "Redis – Solr nodes only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.solr.id]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name}-redis-sg" }
}

resource "aws_security_group" "efs" {
  name        = "${var.name}-efs"
  description = "EFS mount target"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.solr.id, aws_security_group.zookeeper.id, aws_security_group.redis.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name}-efs-sg" }
}

# ── EFS for persistent data ──────────────────────────────────────────────────────
resource "aws_efs_file_system" "solr" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  lifecycle_policy { transition_to_ia = "AFTER_30_DAYS" }
  tags = { Name = "${var.name}-efs" }
}

resource "aws_efs_mount_target" "solr" {
  count           = 3
  file_system_id  = aws_efs_file_system.solr.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "zookeeper" {
  count          = 3
  file_system_id = aws_efs_file_system.solr.id
  root_directory {
    path = "/zookeeper/${count.index + 1}"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }
  tags = { Name = "${var.name}-efs-zk-${count.index + 1}" }
}

resource "aws_efs_access_point" "solr" {
  count          = 3
  file_system_id = aws_efs_file_system.solr.id
  root_directory {
    path = "/solr/${count.index + 1}"
    creation_info {
      owner_gid   = 8983
      owner_uid   = 8983
      permissions = "755"
    }
  }
  tags = { Name = "${var.name}-efs-solr-${count.index + 1}" }
}

resource "aws_efs_access_point" "redis" {
  file_system_id = aws_efs_file_system.solr.id
  root_directory {
    path = "/redis"
    creation_info {
      owner_gid   = 999
      owner_uid   = 999
      permissions = "755"
    }
  }
  tags = { Name = "${var.name}-efs-redis" }
}

# ── Key pair ────────────────────────────────────────────────────────────────────
resource "aws_key_pair" "deploy" {
  key_name   = "${var.name}-deploy-key"
  public_key = var.ssh_public_key
}

# ── IAM (allow EC2 to pull from GHCR via SSM Parameter) ─────────────────────────
resource "aws_iam_role" "ec2" {
  name = "${var.name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ── EC2: ZooKeeper + Solr nodes (1 of each per instance) ────────────────────────
resource "aws_instance" "solr_zk" {
  count                       = 3
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.solr_instance_type
  subnet_id                   = aws_subnet.public[count.index].id
  key_name                    = aws_key_pair.deploy.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids      = [aws_security_group.solr.id, aws_security_group.zookeeper.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    zoo_my_id  = count.index + 1
    efs_id     = aws_efs_file_system.solr.id
    image_tag  = var.image_tag
    image_repo = var.image_repo
    registry   = var.registry
    redis_host = aws_instance.redis.private_ip
    node_index = count.index
    # Solr uses the NLB DNS name – no individual ZK IPs needed
    zk_lb_dns  = aws_lb.zookeeper.dns_name
  }))

  tags = {
    Name = "${var.name}-node-${count.index + 1}"
    Role = "solr-zookeeper"
  }
}

# ── EC2: Redis ───────────────────────────────────────────────────────────────────
resource "aws_instance" "redis" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.redis_instance_type
  subnet_id                   = aws_subnet.public[0].id
  key_name                    = aws_key_pair.deploy.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids      = [aws_security_group.redis.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(templatefile("${path.module}/user-data-redis.sh", {
    efs_id     = aws_efs_file_system.solr.id
    image_tag  = var.image_tag
    image_repo = var.image_repo
    registry   = var.registry
  }))

  tags = { Name = "${var.name}-redis", Role = "redis" }
}

# ── ALB ──────────────────────────────────────────────────────────────────────────
resource "aws_lb" "solr" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "solr" {
  name     = "${var.name}-solr-tg"
  port     = 8983
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/solr/admin/info/system"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }
}

resource "aws_lb_target_group_attachment" "solr" {
  count            = 3
  target_group_arn = aws_lb_target_group.solr.arn
  target_id        = aws_instance.solr_zk[count.index].id
  port             = 8983
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.solr.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.solr.arn
  }
}

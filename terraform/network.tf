# Reuse the account's default VPC/subnet - no NAT gateway or extra networking
# costs, and it's the simplest thing that satisfies the free-tier constraint.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Auto-detect the operator's public IP so the security group can be scoped to
# "just me" instead of the whole internet, unless the caller overrides it.
data "http" "my_ip" {
  count = var.allowed_ip_override == "" ? 1 : 0
  # api.ipify.org is IPv4-only (no AAAA record), unlike ifconfig.me which
  # returns whichever protocol the client connects with. This security group
  # only supports IPv4 CIDRs.
  url = "https://api.ipify.org"
}

locals {
  allowed_cidr = var.allowed_ip_override != "" ? var.allowed_ip_override : "${chomp(data.http.my_ip[0].response_body)}/32"
}

resource "aws_security_group" "elasticsearch" {
  name        = "${var.project_name}-sg"
  description = "SSH and Elasticsearch HTTPS, restricted to the operator IP only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  ingress {
    description = "Elasticsearch HTTPS from operator"
    from_port   = 9200
    to_port     = 9200
    protocol    = "tcp"
    cidr_blocks = [local.allowed_cidr]
  }

  egress {
    description = "Allow all outbound (package installs, SSM, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

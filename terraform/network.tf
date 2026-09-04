data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "http" "my_ip" {
  count = var.allowed_ip_override == "" ? 1 : 0
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

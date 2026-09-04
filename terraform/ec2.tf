data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] 

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "elasticsearch" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/generated/${var.project_name}-key.pem"
  file_permission = "0600"
}

resource "aws_instance" "elasticsearch" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.elasticsearch.key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.elasticsearch.id]
  iam_instance_profile   = aws_iam_instance_profile.elasticsearch_instance.name

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required" 
  }

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tpl", {
    elasticsearch_version = var.elasticsearch_version
    aws_region            = var.aws_region
    ssm_password_param    = local.ssm_password_param
    ssm_ca_param          = local.ssm_ca_param
  })
  user_data_replace_on_change = true

  tags = {
    Name = "${var.project_name}-node"
  }
}

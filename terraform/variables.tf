variable "aws_region" {
  description = "AWS region to deploy into. us-east-1 keeps things on the free tier across the widest range of account types."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3.micro is free-tier eligible in most regions/accounts; fall back to t2.micro if yours isn't."
  type        = string
  default     = "t3.micro"
}

variable "elasticsearch_version" {
  description = "Elasticsearch version to install from Elastic's apt repo. Pinned for reproducibility."
  type        = string
  default     = "8.15.3"
}

variable "project_name" {
  description = "Short name used to tag/name resources and namespace the SSM parameter path."
  type        = string
  default     = "es-demo"
}

variable "allowed_ip_override" {
  description = <<-EOT
    CIDR allowed to reach SSH (22) and Elasticsearch (9200), e.g. "203.0.113.4/32".
    Leave empty to auto-detect the machine running `terraform apply` via ifconfig.me.
    Never leave this as 0.0.0.0/0 - Elasticsearch and SSH must not be open to the internet.
  EOT
  type        = string
  default     = ""
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB. Free tier covers up to 30GB of gp2/gp3 per month."
  type        = number
  default     = 16
}

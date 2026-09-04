# Instance role scoped to exactly one action the box needs to perform:
# writing (and later, us reading back) the generated elastic superuser
# password under this project's SSM parameter path. Nothing broader.
data "aws_caller_identity" "current" {}

locals {
  ssm_password_param = "/${var.project_name}/elastic-password"
  ssm_ca_param       = "/${var.project_name}/http-ca-cert"
}

resource "aws_iam_role" "elasticsearch_instance" {
  name = "${var.project_name}-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ssm_parameter_access" {
  name = "${var.project_name}-ssm-parameter-access"
  role = aws_iam_role.elasticsearch_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:PutParameter",
        "ssm:GetParameter",
      ]
      Resource = [
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_password_param}",
        "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_ca_param}",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "elasticsearch_instance" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.elasticsearch_instance.name
}

output "instance_public_ip" {
  description = "Public IP of the Elasticsearch node"
  value       = aws_instance.elasticsearch.public_ip
}

output "ssh_command" {
  description = "SSH into the instance using the Terraform-generated key"
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ubuntu@${aws_instance.elasticsearch.public_ip}"
}

output "fetch_password_command" {
  description = "Retrieve the generated elastic superuser password from SSM Parameter Store"
  value       = "aws ssm get-parameter --region ${var.aws_region} --name '${local.ssm_password_param}' --with-decryption --query Parameter.Value --output text"
}

output "fetch_ca_cert_command" {
  description = "Retrieve the Elasticsearch HTTP CA certificate from SSM Parameter Store"
  value       = "aws ssm get-parameter --region ${var.aws_region} --name '${local.ssm_ca_param}' --query Parameter.Value --output text > http_ca.crt"
}

output "example_curl_command" {
  description = "Example authenticated, TLS-verified request against the cluster once the two commands above have been run"
  value       = "curl --cacert http_ca.crt -u elastic:<password-from-ssm> https://${aws_instance.elasticsearch.public_ip}:9200/_cluster/health?pretty"
}

output "verify_script" {
  description = "Or just run this from the repo root, which does all of the above for you"
  value       = "./scripts/verify.sh"
}

output "aws_region" {
  value = var.aws_region
}

output "ssm_password_param_name" {
  value = local.ssm_password_param
}

output "ssm_ca_param_name" {
  value = local.ssm_ca_param
}

output "ssh_private_key_path" {
  value = local_sensitive_file.private_key.filename
}

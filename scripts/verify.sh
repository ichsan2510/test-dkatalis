#!/usr/bin/env bash
# Run from the repo root after `terraform apply` to prove the Elasticsearch
# node is actually up, requires credentials, and only talks TLS.
#
# Needs: terraform outputs from a completed apply, and AWS credentials with
# permission to read the SSM parameters this project wrote (the same
# credentials used for `terraform apply` already have that).
set -euo pipefail

cd "$(dirname "$0")/.."

TF_DIR="terraform"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

region="$(terraform -chdir="$TF_DIR" output -raw aws_region)"
public_ip="$(terraform -chdir="$TF_DIR" output -raw instance_public_ip)"
password_param="$(terraform -chdir="$TF_DIR" output -raw ssm_password_param_name)"
ca_param="$(terraform -chdir="$TF_DIR" output -raw ssm_ca_param_name)"

echo "==> Fetching elastic password and CA cert from SSM Parameter Store..."
password="$(aws ssm get-parameter --region "$region" --name "$password_param" \
  --with-decryption --query Parameter.Value --output text)"

aws ssm get-parameter --region "$region" --name "$ca_param" \
  --query Parameter.Value --output text > "$WORKDIR/http_ca.crt"

echo "==> Cluster health (TLS-verified, authenticated):"
curl --cacert "$WORKDIR/http_ca.crt" -u "elastic:$password" -s \
  "https://$public_ip:9200/_cluster/health?pretty"

echo
echo "==> Nodes:"
curl --cacert "$WORKDIR/http_ca.crt" -u "elastic:$password" -s \
  "https://$public_ip:9200/_cat/nodes?v"

echo
echo "==> Confirming unauthenticated requests are rejected:"
curl --cacert "$WORKDIR/http_ca.crt" -s -o /dev/null -w "HTTP %{http_code} (expect 401)\n" \
  "https://$public_ip:9200/_cluster/health"

echo
echo "==> Confirming plaintext HTTP is not served (expect a connection failure/reset):"
if curl -s -m 5 -o /dev/null "http://$public_ip:9200/"; then
  echo "WARNING: plaintext HTTP responded - this should not happen"
else
  echo "OK: no plaintext response"
fi

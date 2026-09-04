#!/usr/bin/env bash
# Cloud-init bootstrap for a single Elasticsearch node.
#
# Security model:
#   - Installing a fresh Elasticsearch node triggers its built-in security
#     auto-configuration: it generates a CA plus HTTP/transport TLS certs and
#     enables authentication automatically. We rely on that (and verify it
#     actually happened) instead of hand-rolling a cert pipeline.
#   - The generated `elastic` superuser password never touches disk in
#     plaintext or gets echoed to a log: it's minted, pushed straight to SSM
#     Parameter Store as a SecureString, and unset. `set -x` tracing is
#     disabled for that whole block.
set -euo pipefail

exec > >(tee -a /var/log/es-bootstrap.log) 2>&1
set -x

ES_VERSION="${elasticsearch_version}"
AWS_REGION="${aws_region}"
SSM_PASSWORD_PARAM="${ssm_password_param}"
SSM_CA_PARAM="${ssm_ca_param}"

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y apt-transport-https gnupg curl unzip

# AWS CLI v2 (apt's packaged awscli is an outdated v1 build). NOTE: this
# fetches AWS's "latest" installer without verifying its GPG signature -
# a time sacrifice called out in the README, not an oversight.
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

# Elastic's official apt repository, GPG-verified via signed-by (no
# add-apt-repository / apt-key, both of which are deprecated).
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elastic.gpg
echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  > /etc/apt/sources.list.d/elastic-8.x.list
apt-get update -y

apt-get install -y "elasticsearch=$ES_VERSION"

CONF=/etc/elasticsearch/elasticsearch.yml

# Fail closed: if auto-configuration didn't run (e.g. this deb was somehow
# not a genuinely fresh install), do not start an unsecured node.
if ! grep -q '^xpack.security.enabled: true' "$CONF"; then
  echo "FATAL: Elasticsearch security auto-configuration did not run - refusing to start an unsecured node." >&2
  exit 1
fi

# Auto-config doesn't set these. discovery.type=single-node is what makes a
# lone node safe to bootstrap without a multi-node quorum; network.host
# opens it up beyond localhost (access is still locked down at the AWS
# security-group layer to the operator's IP only, not by relying on this).
cat >> "$CONF" <<EOF
discovery.type: single-node
network.host: 0.0.0.0
EOF

# t3.micro only has 1GiB RAM; cap the heap explicitly instead of letting
# Elasticsearch's automatic sizing (tuned for bigger boxes) overcommit it.
mkdir -p /etc/elasticsearch/jvm.options.d
cat > /etc/elasticsearch/jvm.options.d/heap.options <<EOF
-Xms512m
-Xmx512m
EOF

systemctl daemon-reload
systemctl enable --now elasticsearch

CA_CERT=/etc/elasticsearch/certs/http_ca.crt

echo "Waiting for Elasticsearch to accept TLS connections..."
for i in $(seq 1 60); do
  if curl --cacert "$CA_CERT" -s -o /dev/null "https://localhost:9200"; then
    break
  fi
  sleep 5
done

# --- sensitive section: no xtrace, credential never echoed or written to disk in plaintext ---
set +x
PASSWORD="$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -b -s)"

aws ssm put-parameter \
  --region "$AWS_REGION" \
  --name "$SSM_PASSWORD_PARAM" \
  --type SecureString \
  --overwrite \
  --value "$PASSWORD" >/dev/null

aws ssm put-parameter \
  --region "$AWS_REGION" \
  --name "$SSM_CA_PARAM" \
  --type String \
  --overwrite \
  --value "$(cat "$CA_CERT")" >/dev/null

# On-box proof it actually came up secured and working, without leaking the
# password into this (non-sensitive-log) file - it only appears in the URL
# form curl needs, and this whole block still has xtrace disabled.
curl --cacert "$CA_CERT" -u "elastic:$PASSWORD" -s https://localhost:9200/_cluster/health?pretty \
  > /var/log/es-bootstrap-verify.log

unset PASSWORD
set -x
# --- end sensitive section ---

echo "Bootstrap complete."

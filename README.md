# Secure single-node Elasticsearch on AWS (free tier)

Terraform brings up one EC2 instance and bootstraps a single Elasticsearch node. Credentials required, TLS only, all from one `terraform apply`.

## What this deploys

- One `t3.micro` EC2 instance (Ubuntu 22.04 LTS) in the default VPC. Free-tier eligible.
- A security group that only allows SSH (22) and Elasticsearch (9200) from your current public IP, auto-detected at plan time. Nothing is open to `0.0.0.0/0`.
- Elasticsearch 8.x, installed through cloud-init (`terraform/templates/bootstrap.sh.tpl`). Its built-in security auto-configuration does most of the work here: TLS certs for both HTTP and transport, and a required `elastic` superuser password, both generated automatically on first install.
- The generated password gets rotated immediately and pushed to AWS SSM Parameter Store as a `SecureString`, so it's never sitting in a log file or on disk in plaintext. The instance's IAM role can only touch that one parameter path.
- `scripts/verify.sh` - run it after `apply` to check the cluster is healthy, auth is actually enforced, and plaintext HTTP isn't being served.

## Why Terraform only, no Ansible

There are really two jobs here: provision the instance and bootstrap it. Terraform's `user_data` can do both in one `apply`, so there's no need for SSH orchestration or a "wait until the host is reachable" step that a Terraform+Ansible combo would need. For a single disposable box that's just extra moving parts for no real benefit. Ansible starts to make sense once you need idempotent re-configuration of already-running hosts, or more complex multi-host orchestration - if this grows into a fleet that needs frequent config changes without replacing hosts, that's the next tool I'd reach for (or baking config into a golden AMI with Packer).

## Why Elasticsearch's own security auto-configuration, not hand-rolled certs

Elasticsearch 8.x turns on auth and TLS by default the moment it's freshly installed - it generates its own CA, issues HTTP and transport certs off it, and creates a one-time password for `elastic`, all during the `apt-get install` step. Hand-rolling this with `openssl`/`elasticsearch-certutil` is a fine approach too (it's what the multi-node section below would actually need), but for one node it's just reimplementing something Elasticsearch already handles correctly. The bootstrap script checks that auto-configuration actually happened (looks for `xpack.security.enabled: true` in `elasticsearch.yml`) and refuses to start the service if it didn't.

## Getting the credential and CA cert off the box safely

`elasticsearch-reset-password -u elastic -b -s` generates a fresh password non-interactively. The bootstrap script turns off `set -x` for that section so the value never ends up in `/var/log/cloud-init-output.log`, pushes it to SSM as a `SecureString`, then unsets the shell variable right away. The HTTP CA cert also goes to SSM, as a plain `String` this time since it's meant to be public - a client needs it to verify the server - which means an operator can grab it without ever SSHing into the box.

## Usage

```bash
cd terraform
terraform init
terraform apply          # review the plan, then confirm

chmod +x ../scripts/verify.sh
../scripts/verify.sh     # checks the cluster is up, authenticated, and TLS-only
```

Requires Terraform >= 1.5, AWS credentials with EC2/IAM/SSM permissions available in your environment (`aws configure` or similar), and the AWS CLI locally for `verify.sh`.

To tear down: `terraform destroy` from `terraform/`.

### Additional AWS services used beyond the EC2 instance

- **SSM Parameter Store** - free tier covers this usage pattern (low volume, standard params, no advanced tier).
- **IAM** (role + instance profile) - no cost.
- Default VPC/subnet, its existing internet gateway, and a security group - no cost on their own (no NAT gateway involved).

## How long this took

Roughly 2.5-3 hours total. Most of it went into the bootstrap script's security section - getting the password handling and the "wait until ES is actually ready" logic right took a few tries. One thing I'd flag on the brief itself: it doesn't say much about instance sizing, and Elasticsearch's official minimums don't really fit a free-tier `t3.micro` (1GiB RAM). More on that in the sacrifices section.

## Resources consulted

- Elastic docs: [security auto-configuration](https://www.elastic.co/guide/en/elasticsearch/reference/current/configuring-stack-security.html), [`elasticsearch-reset-password`](https://www.elastic.co/guide/en/elasticsearch/reference/current/reset-password.html), [`elasticsearch-certutil`](https://www.elastic.co/guide/en/elasticsearch/reference/current/certutil.html), [apt install](https://www.elastic.co/guide/en/elasticsearch/reference/current/deb.html)
- AWS docs: [SSM SecureString params](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-securestring.html), [EC2 free tier](https://aws.amazon.com/free/), [IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- Terraform registry docs for the `aws`, `tls`, `local`, and `http` providers

---

## Answers to the brief's questions

**1. What did you choose to automate provisioning and bootstrapping, and why?**
Terraform for both, through `user_data`. One tool creates the instance and hands it its full config in the same `apply` - fewer moving parts for a one-shot host, and the same tool that owns the lifecycle (`plan`/`apply`/`destroy`) also proves the box came up right, via outputs.

**2. How did you secure Elasticsearch, and why?**
Two layers, on purpose, so neither one is a single point of failure:
- Network: the security group only lets the operator's own IP hit 22 and 9200. Nothing is internet-facing, and it costs nothing.
- Application: Elasticsearch's own auto-configuration handles TLS on HTTP and transport (so even someone who got network access can't read traffic or spoof the server) plus a mandatory password on `elastic` (so network access alone isn't enough). The bootstrap script actually verifies this turned on before starting the service instead of assuming it did.

Also: EBS encrypted at rest, IMDSv2 enforced (helps against SSRF-to-credential-theft via the metadata endpoint), and the IAM role is scoped to exactly the two SSM parameters it needs - no wildcard resources.

**3. How would you monitor this instance, and what metrics?**
Didn't build this out (see sacrifices) but here's what I'd do:
- Host level: default EC2 metrics skip memory and disk, so I'd add the CloudWatch agent for `mem_used_percent`, disk usage/IOPS, network throughput, alongside the free `CPUUtilization`/`StatusCheckFailed`.
- Elasticsearch level: cluster health (red/yellow/green), JVM heap and GC pause time (especially important given the 512MB heap here), thread pool rejections, disk watermark breaches (ES throttles writes past 85-95% disk usage), query latency, indexing rate. In practice I'd ship these through Metricbeat or the CloudWatch agent, with alarms on status != green and on heap/disk thresholds.

**4. Could this extend to a secure 3-node cluster? What would change?**
Yes, but the security approach has to change too, not just the node count. Auto-configuration is really built for single-node use - joining nodes to a cluster normally goes through short-lived enrollment tokens generated on the first node, and that's timing-sensitive to script reliably against Terraform's parallel instance creation.

The more deterministic path for IaC: generate a CA and per-node certs in Terraform up front (`tls_private_key`/`tls_locally_signed_cert` per node, all off one CA resource), hand each node its cert, key, and the shared CA through per-instance `user_data` (or pull them from SSM at boot instead of embedding key material directly), turn off auto-configuration (`xpack.security.autoconfiguration.enabled: false`), and set `xpack.security.enabled: true` with explicit `http.ssl`/`transport.ssl` blocks. Discovery moves from `discovery.type: single-node` to `discovery.seed_hosts` (the other nodes' private IPs, known at plan time) plus `cluster.initial_master_nodes` for the initial bootstrap. The security group needs an internal rule opening 9300 between the three nodes, still excluding the public internet. Built-in user passwords live in a system index replicated across the cluster, so `elasticsearch-reset-password` only needs to run once, from any node, after the cluster forms.

**5. Could this replace a running instance with little or no downtime?**
Only really with the cluster from Q4 - a single node's data has nowhere to go while it's replaced, so "no downtime" needs at least 3 nodes (or 2, carefully) so shards can move off the node first. Mechanism: exclude the target from allocation (`PUT _cluster/settings` with `cluster.routing.allocation.exclude._name`), wait for `GET _cluster/health?wait_for_no_relocating_shards=true` to confirm its shards moved off, then terminate it and let Terraform bring up a replacement (`create_before_destroy`, or an ASG with rolling instance refresh). Replace one node at a time and don't drop below quorum for master-eligible nodes.

**6. Was code structure/extensibility/reusability a priority?**
Within the time box, yes - Terraform is split by concern (`network.tf`, `iam.tf`, `ec2.tf`) instead of one big file, node count/instance type/ES version are variables instead of hardcoded, and the bootstrap script is a template so the same code path could serve a multi-node variant later. Didn't go further than that (no module boundary, no remote state backend) since a single throwaway demo instance doesn't need it yet, and adding it now would just be guessing at requirements this exercise doesn't actually have.

**7. What did you cut for time?**
- No cluster / no zero-downtime replacement code - designed above (Q4/Q5) but not built. Biggest remaining chunk of work.
- No CloudWatch agent or actual monitoring wired up, just described in Q3.
- AWS CLI v2 install isn't signature-verified. It's pulled over HTTPS from AWS's own domain but I skipped checking the GPG signature AWS publishes for it, unlike the Elastic apt repo which is properly `signed-by` verified. Should fix both in a real build.
- `t3.micro`'s 1GiB RAM is genuinely too small for Elasticsearch. Capped the heap at 512MB to make it fit, which is fine for a health-check demo but well under Elastic's own recommendations and wouldn't hold up under real load. A real deployment needs at least `t3.small`/`m6g.large` class, outside free tier.
- Only `elastic` (superuser) exists - no scoped-down app user, which is what you'd actually want for client traffic instead of handing out superuser creds.
- No remote Terraform state backend (S3 + DynamoDB locking). Fine for one person running this once, not fine for a team.

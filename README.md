# Cloud SUSE Observability: SUSE Observability on an RKE2 cluster, via Terraform

This project contains Terraform code to deploy an RKE2 cluster on Amazon Web Services and install [SUSE Observability](https://documentation.suse.com/cloudnative/suse-observability/) onto it via Helm. It follows the same patterns as [cloud-rancher](https://github.com/nbornstein/cloud-rancher) (per-cloud `*-aws.tf` files, the same DNS/TLS option set, SCC de-registration on destroy) but only targets AWS for now - `cloud_provider` is kept as a variable, restricted to `"aws"`, so Azure/GCP support can be added later the same way cloud-rancher structures it, without reworking the cloud-agnostic files (`compute.tf`, `dns.tf`, `outputs.tf`).

## Architecture

This configuration creates the following resources in your AWS account:

*   **Networking**: A VPC, a dedicated subnet for the RKE2 nodes, and security group rules controlling inbound traffic (SSH, HTTP, HTTPS, Kube-API). SSH (22) and the Kube-API (6443) are restricted by default to the IP running `terraform apply` - set `allowed_admin_cidr_blocks` to change this (e.g. to `["0.0.0.0/0"]` to reopen them to everyone). Ports 80 and 443 are always open: 80 for the Let's Encrypt HTTP-01 challenge, and 443 because the ingress controller's own TLS + SUSE Observability's auth protect it, and agents reporting data in need to reach it from node IPs that have nothing to do with wherever `terraform apply` was run.
*   **Virtual Machines**: A 1-node (standalone) or 3-node (HA control plane) RKE2 cluster running on SLES 15 SP7 EC2 instances. The first node bootstraps the cluster and installs SUSE Observability; for a 3-node setup, the other two join as additional servers.
*   **IAM Role / Instance Profile**: Attached to every node, granting the [AWS EBS CSI driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver) (installed by the boot script) permission to provision EBS volumes via AWS's `AmazonEBSCSIDriverPolicy` managed policy. This is the one significant infrastructure difference from cloud-rancher: SUSE Observability's own services (OpenSearch, ClickHouse, Kafka, etc.) need a working dynamic `StorageClass` for their `PersistentVolumeClaim`s, and plain RKE2 - unlike EKS - ships no CSI driver or default `StorageClass` at all. There's no OIDC/IRSA to scope credentials through outside EKS, so the driver authenticates the same way anything else on the instance would: via this instance profile.
*   **Public IPs**: One for each cluster node (for direct SSH access), plus a static public IP for the Load Balancer frontend.
*   **Load Balancer**: An AWS Network Load Balancer distributing traffic to the RKE2 cluster nodes (Kube-API, HTTP, HTTPS).
*   **Route 53 A Records**: If enabled, one for the SUSE Observability FQDN (`observability.YOUR_DOMAIN`) and one per cluster node (`observability-node-X.YOUR_DOMAIN`).

The first node runs a setup script via EC2 `user_data` to:
1.  Register the SLES operating system with SUSE Customer Center.
2.  Install RKE2 as a server.
3.  Install `cert-manager` for automated TLS certificate management.
4.  Install the AWS EBS CSI driver and mark its `gp3` StorageClass as the cluster default.
5.  Deploy SUSE Observability via Helm, with TLS from either Let's Encrypt or a custom certificate pulled from AWS Secrets Manager (TLS is always terminated by the ingress controller, never by SUSE Observability itself - see [TLS / Certificate Options](#tls--certificate-options)).
6.  Wait for every SUSE Observability component to report healthy before the script - and `terraform apply` - exits.

In a 3-node setup, the other two nodes run a simpler script to join this same RKE2 cluster as additional servers; SUSE Observability itself is only ever installed once, from the first node.

## Prerequisites

*   Terraform (>= 1.3.0)
*   AWS CLI, configured with credentials.
*   `jq` (for SCC de-registration on destroy)
*   An SSH public key (e.g., in `~/.ssh/id_rsa.pub`).

You will also need:
*   A SUSE Linux Enterprise Server (SLES) registration code from the SUSE Customer Center, used to register the OS on each node.
*   A **SUSE Observability license key**. This is distinct from the SLES registration code above - SUSE Observability is licensed directly via a key passed to its Helm chart (`global.suseObservability.license`), not via a SUSE Customer Center product registration the way Rancher Prime is in cloud-rancher.

## Configuration

1.  **Authenticate with AWS**:
    ```sh
    aws configure
    ```

2.  **Create a variables file**: This project uses a `terraform.tfvars` file to manage secrets and environment-specific settings. This file is ignored by Git. Copy [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example) to `terraform/terraform.tfvars` and fill in the values for your deployment.
    ```sh
    cp terraform/terraform.tfvars.example terraform/terraform.tfvars
    ```

## Sizing

SUSE Observability's resource needs are driven by `suse_observability_sizing_profile`, not a value you pick independently of your instance type. Straight from the [official requirements table](https://documentation.suse.com/cloudnative/suse-observability/latest/en/setup/install-stackstate/requirements.html):

| Profile | CPU requested | Memory requested | Storage | Min nodes |
|---|---|---|---|---|
| `trial` | 7.2 | 23.4Gi | 154Gi | 1 |
| `10-nonha` | 7.2 | 23.4Gi | 335Gi | 1 |
| `20-nonha` | 9.5 | 27.2Gi | 375Gi | 1 |
| `50-nonha` | 14.2 | 32.6Gi | 475Gi | 1 |
| `100-nonha` | 24.1 | 45.7Gi | 525Gi | 1 |
| `150-ha` | 49.8 | 130.7Gi | 2595Gi | 3 |
| `250-ha` | 61.8 | 145.9Gi | 2695Gi | 3 |
| `500-ha` | 85.3 | 176.1Gi | 3595Gi | 3 |
| `4000-ha` | 212.3 | 267.6Gi | 6995Gi | 5 |

For any `*-nonha` profile, `cluster_node_count = 1` is enough, but that single node's `aws_instance_type` must have enough spare capacity for the *entire* row above - requests aren't spread across nodes that don't exist. The default `aws_instance_type` (`m5.4xlarge`: 16 vCPU / 64GiB) comfortably covers every `*-nonha` profile. Moving to an `*-ha` profile is a one-way decision in SUSE Observability (you cannot migrate a `nonha` install to `ha` later) and needs `cluster_node_count = 3` or `5` plus a correspondingly larger `aws_instance_type` - read the full requirements page before committing to one.

## DNS Options

SUSE Observability needs a hostname that resolves to the Load Balancer's public IP, both so you can reach the UI and so cert-manager can complete the Let's Encrypt HTTP-01 challenge. Pick one, exactly as in cloud-rancher:

1.  **AWS Route53** (`aws_create_route53_record = true`): Terraform creates the `A` record for you in a Route53 hosted zone you own.
2.  **sslip.io** (`use_sslip_io = true`): No domain, DNS provider, or AWS account needed. The hostname is derived automatically from the Load Balancer's public IP (e.g. `20-1-2-3.sslip.io`) and is available as the `observability_url` Terraform output.
3.  **Manual**: Set `suse_observability_hostname` to a hostname you manage elsewhere, and point its `A` record at the Load Balancer's public IP (the `load_balancer_public_ip` output) yourself.

## TLS / Certificate Options

SUSE Observability doesn't terminate TLS itself - that's always the ingress controller's job. Pick one:

1.  **Let's Encrypt** (`use_letsencrypt = true`, the default): `cert-manager` requests a certificate automatically via the HTTP-01 challenge against `suse_observability_hostname`, using `letsencrypt_email` as the account contact.
2.  **Custom certificate from AWS Secrets Manager** (`use_letsencrypt = false`): Terraform reads `aws_tls_cert_secret_arn`, a Secrets Manager secret whose value is a JSON object with `tls.crt` and `tls.key` keys (PEM-encoded), and creates the `suse-observability/tls-observability-ingress` secret from them.

## AWS IAM Permissions

Several things in this project call AWS APIs, each independently optional and needing its own permissions on the IAM user or role Terraform/the AWS CLI uses:

*   Creating/destroying the VPC, subnet, security group, EC2 instances, Elastic IPs, Network Load Balancer, and the EBS CSI driver's IAM role/instance profile.
*   Route 53 (`aws_create_route53_record = true`): creating the DNS record.
*   Custom certificates from AWS Secrets Manager (`use_letsencrypt = false`): reading the cert secret.

Attach only the policy/policies below matching the integrations you're actually using.

### RKE2/SUSE Observability compute

Policy: [`iam-policies/aws-observability-compute.json`](iam-policies/aws-observability-compute.json)

Like cloud-rancher's equivalent policy, `ec2:*`/`elasticloadbalancing:*` actions that don't support resource-level scoping are granted broadly (matching AWS's own `AmazonEC2FullAccess`/`ElasticLoadBalancingFullAccess` managed policies), while the IAM role/instance-profile management needed for the EBS CSI driver is scoped to resources named `suse-observability-*`.

### Route 53 (`aws_create_route53_record = true`)

Policy: [`iam-policies/aws-route53.json`](iam-policies/aws-route53.json)

**Remember to replace `YOUR_ROUTE53_ZONE_ID` with your actual hosted zone ID.**

### Secrets Manager custom TLS certificate (`use_letsencrypt = false`)

Policy: [`iam-policies/aws-secrets-manager-custom-tls.json`](iam-policies/aws-secrets-manager-custom-tls.json)

**Remember to replace `YOUR_SECRET_ARN` with your actual secret ARN.**

## Deployment

1.  **Initialize Terraform**:
    ```sh
    cd terraform
    terraform init
    ```

2.  **Plan the deployment**:
    ```sh
    terraform plan
    ```

3.  **Apply the configuration**:
    ```sh
    terraform apply
    ```
    This can take up to 40 minutes: it involves provisioning VMs, bootstrapping RKE2, installing the EBS CSI driver, and installing/waiting on every SUSE Observability pod (OpenSearch, ClickHouse, Kafka, and the rest) to become ready. Terraform polls the ingress endpoint and only completes once it receives a successful, TLS-valid response.

## Accessing SUSE Observability

Once the deployment is complete, check the `observability_url` Terraform output for the UI address and log in as `admin` with the `suse_observability_admin_password` you set. The `receiver_url` output is the endpoint agents should report data to.

## Cleanup

```sh
terraform destroy
```

### Automatic De-registration

If you provide `scc_username` and `scc_password`, Terraform automatically de-registers every SLES node from the SUSE Customer Center on `terraform destroy`, identified by its machine hostname (e.g. `vm-observability-node-1`). The process is handled by a `destroy` provisioner and requires `jq`. If credentials are not provided, this step is skipped. SUSE Observability's own license isn't an SCC registration, so there's nothing to de-register for it specifically.

**Note**: The `deregister-scc.sh` script must be executable:
```sh
chmod +x deregister-scc.sh
```

## Scope

This is a scaffold, intentionally narrower than cloud-rancher: AWS only (no Azure/GCP yet), no downstream-cluster provisioning, no Fleet-based add-ons, and no AI Assistant equivalent. Extending it to additional clouds should follow cloud-rancher's pattern - add `network-azure.tf`/`compute-azure.tf`/etc., extend `cloud_provider`'s validation, and update the views in `compute.tf`'s `locals` block.

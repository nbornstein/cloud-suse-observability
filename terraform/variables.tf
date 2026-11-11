# --- Cloud Provider Selection ---

variable "cloud_provider" {
  type        = string
  description = "Which cloud hosts the RKE2/SUSE Observability VMs, VPC, and load balancer. Only \"aws\" is supported today - this mirrors cloud-rancher's cloud_provider variable so Azure/GCP support can be added the same way later. This is independent of the AWS provider used for Route53 DNS records and the Secrets Manager custom TLS cert option, both of which can be used regardless of which cloud hosts the VMs."
  default     = "aws"

  validation {
    condition     = contains(["aws"], var.cloud_provider)
    error_message = "cloud_provider must be \"aws\" - it's the only supported value today."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key content for EC2 instance access. If not provided, the content of ~/.ssh/id_rsa.pub is used as a fallback."
  default     = null
}

variable "allowed_admin_cidr_blocks" {
  type        = list(string)
  description = "CIDR blocks allowed to reach SSH (22) and the Kube-API (6443). Leave as [] (the default) to auto-detect and allow only the IP running `terraform apply`. Set to [\"0.0.0.0/0\"] to reopen access to everyone. Ports 80 and 443 are always left open to the world: 80 for the Let's Encrypt HTTP-01 challenge, and 443 because the ingress controller terminates TLS there, plus agents reporting into SUSE Observability connect from node IPs unrelated to wherever `terraform apply` was run."
  default     = []
}

# --- AWS Compute (VPC, EC2, Load Balancer) ---
#
# Distinct from the aws_route53_* and aws_tls_cert_secret_arn variables below,
# which configure separate, optional AWS integrations (DNS and custom TLS
# certs) that happen to also be AWS, regardless of cloud_provider.

variable "aws_region" {
  type        = string
  description = "AWS region for the VPC, EC2 instances, and load balancer. Resolved independently of the AWS provider used for Route53/Secrets Manager, which continues to use your AWS CLI/environment's default region."
  default     = null
}

variable "aws_vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC created for the RKE2 cluster."
  default     = "10.3.0.0/16"
}

variable "aws_admin_username" {
  type        = string
  description = "SSH login username for the AWS SLES AMI."
  default     = "ec2-user"
}

variable "aws_ami_id" {
  type        = string
  description = "AMI ID to use for the SLES 15 SP7 instances. Leave \"\" to auto-discover the latest SLES 15 SP7 BYOS AMI published by aws_sles_ami_owner_id in aws_region. Override this if that lookup picks the wrong image for your account/region - check with `aws ec2 describe-images --owners <aws_sles_ami_owner_id> --filters \"Name=name,Values=suse-sles-15-sp7-byos-v????????-hvm-ssd-x86_64-prod-*\"`."
  default     = ""
}

variable "aws_sles_ami_owner_id" {
  type        = string
  description = "AWS account ID that publishes the SLES AMIs used by the aws_ami_id auto-discovery lookup. Defaults to SUSE's current AWS Marketplace publishing account - see cloud-rancher's README for how this was verified. Only used when aws_ami_id is \"\"."
  default     = "679593333241"
}

variable "aws_instance_type" {
  type        = string
  description = <<-EOT
    EC2 instance type for each RKE2/SUSE Observability node. SUSE Observability's
    resource *requests* (not the node's total capacity) for a few sizing profiles,
    straight from the official requirements table - a single non-HA node must fit
    the whole total, since nothing else schedules it elsewhere:
      trial        ->  7.2 vCPU /  23.4Gi memory requested (min node: 4 vCPU/8GB)
      10-nonha     ->  7.2 vCPU /  23.4Gi memory requested
      20-nonha     ->  9.5 vCPU /  27.2Gi memory requested
      50-nonha     -> 14.2 vCPU /  32.6Gi memory requested
      100-nonha    -> 24.1 vCPU /  45.7Gi memory requested
      150-ha+      -> 49.8+ vCPU / 130.7Gi+ memory requested, spread across >= 3 nodes
    The default below (m5.4xlarge: 16 vCPU/64GiB) comfortably fits every *-nonha
    profile on a single node. For a 150-ha or larger profile, raise this and set
    cluster_node_count = 3 (or more) so the total RKE2 cluster capacity covers it -
    see https://documentation.suse.com/cloudnative/suse-observability/latest/en/setup/install-stackstate/requirements.html
    for the full table before sizing a non-trial deployment.
  EOT
  default     = "m5.4xlarge"
}

# --- RKE2 cluster ---

variable "cluster_node_count" {
  type        = number
  description = "Number of nodes in the RKE2 cluster that SUSE Observability is installed onto. Can be 1 (standalone) or 3 (HA control plane). This is independent of SUSE Observability's own sizing.profile HA/non-HA distinction (see suse_observability_sizing_profile) - that controls redundancy of Observability's internal services, not the Kubernetes control plane."
  default     = 1

  validation {
    condition     = contains([1, 3], var.cluster_node_count)
    error_message = "The number of RKE2 cluster nodes must be 1 or 3."
  }
}

variable "rke2_token" {
  type        = string
  description = "Shared secret token used by RKE2 cluster nodes to join the cluster"
  sensitive   = true
}

variable "rke2_version" {
  description = <<-EOT
    The version of RKE2 to install (e.g., v1.35.9+rke2r1). Defaults to the
    latest v1.35.x release rather than the overall latest RKE2 release, since
    starting with RKE2 v1.36, Traefik replaces ingress-nginx as the default
    packaged ingress controller. This project detects which one is in play
    from this version string (treating "" as the latest release, i.e. >= 1.36)
    and configures RKE2, cert-manager's ClusterIssuer, and the SUSE
    Observability ingress values to use the matching ingress controller
    automatically - no other changes are needed to move between them.
  EOT
  type        = string
  default     = "v1.35.9+rke2r1"
}

variable "cert_manager_version" {
  description = "The version of cert-manager to install."
  type        = string
  default     = "v1.13.1"
}

# --- SUSE Observability ---

variable "suse_observability_license" {
  type        = string
  description = "SUSE Observability license key (global.suseObservability.license in the Helm chart). Obtained from SUSE - this is a license key, not a SUSE Customer Center registration code like sles_reg_code below."
  sensitive   = true
}

variable "suse_observability_admin_password" {
  type        = string
  description = "Initial password for the SUSE Observability 'admin' user (global.suseObservability.adminPassword in the Helm chart)."
  sensitive   = true
}

variable "suse_observability_sizing_profile" {
  type        = string
  description = "SUSE Observability sizing profile (global.suseObservability.sizing.profile in the Helm chart), which determines the resources requested by its internal services and the max number of Kubernetes nodes it can observe. One of the values below - see aws_instance_type's description and https://documentation.suse.com/cloudnative/suse-observability/latest/en/setup/install-stackstate/requirements.html for sizing guidance before choosing anything beyond trial/10-nonha."
  default     = "trial"

  validation {
    condition     = contains(["trial", "10-nonha", "20-nonha", "50-nonha", "100-nonha", "150-ha", "250-ha", "500-ha", "4000-ha"], var.suse_observability_sizing_profile)
    error_message = "suse_observability_sizing_profile must be one of: trial, 10-nonha, 20-nonha, 50-nonha, 100-nonha, 150-ha, 250-ha, 500-ha, 4000-ha."
  }
}

variable "suse_observability_chart_version" {
  type        = string
  description = "The version of the suse-observability Helm chart to install. If not set, the latest version from the chart repository is used."
  default     = ""
}

variable "suse_observability_hostname" {
  type        = string
  description = "FQDN for SUSE Observability (global.suseObservability.baseUrl, minus the https:// scheme, which is added automatically). Required unless use_sslip_io is true, in which case it is derived automatically."
  default     = null
}

# --- SUSE registration & Customer Center ---

variable "sles_reg_code" {
  type        = string
  description = "SUSE Linux Enterprise Server Registration Code, used to register the OS on every node via SUSEConnect. SUSE Observability itself is licensed separately via suse_observability_license above, not through SCC."
  sensitive   = true
}

variable "scc_username" {
  type        = string
  description = "Username for SUSE Customer Center API for de-registration on destroy. If not provided, de-registration is skipped."
  default     = null
  sensitive   = true
}

variable "scc_password" {
  type        = string
  description = "Password for SUSE Customer Center API for de-registration on destroy. If not provided, de-registration is skipped."
  default     = null
  sensitive   = true
}

# --- DNS ---
#
# Three ways to get a hostname pointing at the Load Balancer:
#   1. AWS Route53 (aws_create_route53_record = true): Terraform creates the A record.
#   2. sslip.io (use_sslip_io = true): no record to create - the hostname is derived
#      from the Load Balancer's public IP and resolves automatically. No domain,
#      DNS provider, or AWS account needed.
#   3. Manual: set suse_observability_hostname and point it at the Load Balancer's
#      public IP yourself (output as load_balancer_public_ip) using whatever DNS
#      you manage.

variable "domain_name" {
  type        = string
  description = "The base domain name for the deployment (e.g., YOUR_DOMAIN). Only used with Route53."
  default     = null
}

variable "aws_route53_zone_id" {
  type        = string
  description = "The Route53 Zone ID where the SUSE Observability hostname's A record will be created."
  default     = null
}

variable "aws_create_route53_record" {
  type        = bool
  description = "If true, create a Route53 record for the SUSE Observability hostname."
  default     = false
}

variable "use_sslip_io" {
  type        = bool
  description = "If true, skip suse_observability_hostname/DNS entirely and auto-generate a hostname from the Load Balancer's public IP using sslip.io (e.g. 20-1-2-3.sslip.io), which resolves to that IP with no DNS record to create or own domain required."
  default     = false
}

# --- TLS / Certificates ---
#
# SUSE Observability itself doesn't terminate TLS - the ingress controller
# does, same as Rancher's ingress in cloud-rancher. These two options mirror
# that project's TLS handling exactly.

variable "use_letsencrypt" {
  description = "Set to true to use Let's Encrypt for the SUSE Observability ingress certificate. Set to false to use a custom certificate from AWS Secrets Manager."
  type        = bool
  default     = true
}

variable "letsencrypt_email" {
  type        = string
  description = "Email address for Let's Encrypt certificates."
}

variable "aws_tls_cert_secret_arn" {
  description = "The ARN of the secret in AWS Secrets Manager containing the TLS certificate and key. Required if use_letsencrypt is false."
  type        = string
  default     = ""
}

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  # Used for Route53 DNS records and the AWS Secrets Manager custom TLS cert
  # option, regardless of cloud_provider. Assumes you have AWS credentials
  # configured in your environment (e.g., via environment variables or
  # ~/.aws/credentials); region comes from that same environment/profile.
}

# A second, explicitly-regioned AWS provider for the VPC/EC2/load-balancer
# compute resources used when cloud_provider = "aws". Kept separate (via
# alias) from the provider above so Route53/Secrets Manager - which may
# legitimately target a different region - are unaffected by aws_region.
provider "aws" {
  alias  = "compute"
  region = coalesce(var.aws_region, "us-east-1")
}

# Only hit the IP-echo service when the caller hasn't pinned allowed_admin_cidr_blocks
# themselves, since the lookup is an outbound call to a third party and is pointless
# once the list is explicit (e.g. ["0.0.0.0/0"] to reopen access).
data "http" "my_ip" {
  count = length(var.allowed_admin_cidr_blocks) == 0 ? 1 : 0

  url = "https://checkip.amazonaws.com"
}

locals {
  # CIDR blocks allowed to reach SSH/Kube-API/HTTPS: either the caller's explicit
  # override, or the IP running `terraform apply`, auto-detected so the apply-time
  # health check in null_resource.wait_for_observability (compute.tf) always has a
  # path in.
  admin_cidr_blocks = length(var.allowed_admin_cidr_blocks) > 0 ? var.allowed_admin_cidr_blocks : ["${chomp(data.http.my_ip[0].response_body)}/32"]
}

# cloud_provider only supports "aws" today. It's kept as a variable (rather than
# hardcoded) and this config is split into *-aws.tf files - network-aws.tf,
# compute-aws.tf, loadbalancer-aws.tf - the same way cloud-rancher splits by
# cloud_provider, so adding network-azure.tf/compute-azure.tf/etc. later is a
# drop-in rather than a rewrite. Variable "validation" blocks can't reference
# other variables, so the aws_region requirement uses a resource precondition
# instead, which runs at plan time regardless of which resources it precedes.
resource "null_resource" "validate_cloud_provider_config" {
  lifecycle {
    precondition {
      condition     = var.cloud_provider == "aws" && var.aws_region != null && var.aws_region != ""
      error_message = "cloud_provider must be \"aws\" (the only supported value today), and aws_region must be set."
    }
  }
}

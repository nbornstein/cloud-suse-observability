# Fetches the custom TLS certificate from AWS Secrets Manager when not using Let's Encrypt.
data "aws_secretsmanager_secret_version" "custom_cert" {
  count = !var.use_letsencrypt && var.aws_tls_cert_secret_arn != "" ? 1 : 0

  secret_id = var.aws_tls_cert_secret_arn
}

locals {
  # Starting with RKE2 v1.36, Traefik replaces ingress-nginx as the default packaged
  # ingress controller (see var.rke2_version). Derive which one this deployment uses
  # from the version string itself, so the two stay in sync automatically instead of
  # relying on a separate toggle that could drift from the pinned version.
  # An empty rke2_version means "install the absolute latest release", which is >= 1.36.
  rke2_version_parts = var.rke2_version == "" ? ["1", "36"] : regex("^v(\\d+)\\.(\\d+)", var.rke2_version)
  use_traefik = (
    tonumber(local.rke2_version_parts[0]) > 1 ||
    (tonumber(local.rke2_version_parts[0]) == 1 && tonumber(local.rke2_version_parts[1]) >= 36)
  )
  rke2_ingress_controller = local.use_traefik ? "traefik" : "ingress-nginx"
  ingress_daemonset_name  = local.use_traefik ? "rke2-traefik" : "rke2-ingress-nginx-controller"
  ingress_class_name      = local.use_traefik ? "traefik" : "nginx"

  # Decode the custom certificate from AWS Secrets Manager if provided.
  # Gracefully handle missing keys using try().
  custom_cert_data = length(data.aws_secretsmanager_secret_version.custom_cert) > 0 ? jsondecode(data.aws_secretsmanager_secret_version.custom_cert[0].secret_string) : {}
  tls_cert_b64     = base64encode(try(local.custom_cert_data["tls.crt"], ""))
  tls_key_b64      = base64encode(try(local.custom_cert_data["tls.key"], ""))

  # --- Views over the AWS compute resources ---
  # Everything outside compute-aws.tf (DNS, outputs, the waiters/de-registration
  # below) reads these, not the aws_* resources directly - the same indirection
  # cloud-rancher uses to keep cloud-agnostic files from needing a cloud_provider
  # ternary sprinkled through them. Today these are a straight pass-through since
  # aws is the only supported cloud_provider, but keeping the indirection means
  # adding e.g. compute-azure.tf later only touches this one spot.
  lb_public_ip            = aws_eip.lb_eip.public_ip
  cluster_vm_ids          = aws_instance.cluster_vm[*].id
  admin_username          = var.aws_admin_username
  cluster_node_public_ips = aws_eip.cluster_node_eip[*].public_ip
}

# Without this, an empty/misconfigured aws_tls_cert_secret_arn when use_letsencrypt = false
# doesn't fail here - it silently flows through as base64encode("") and only surfaces much
# later as an obscure TLS handshake / ingress-controller failure. A variable "validation"
# block can't reference other variables, so this uses a resource precondition instead,
# which runs at plan time regardless of the custom_cert data source's own count.
resource "null_resource" "validate_custom_cert_config" {
  lifecycle {
    precondition {
      condition = (
        var.use_letsencrypt ||
        (
          var.aws_tls_cert_secret_arn != "" &&
          try(local.custom_cert_data["tls.crt"], "") != "" &&
          try(local.custom_cert_data["tls.key"], "") != ""
        )
      )
      error_message = "When use_letsencrypt = false, aws_tls_cert_secret_arn must point to a Secrets Manager secret containing non-empty 'tls.crt' and 'tls.key' keys."
    }
  }
}

# --- Destroy-time De-registration ---

# This null_resource acts as a hook to run a de-registration script when the
# associated VM is destroyed. This pattern is necessary because a destroy-time
# provisioner cannot directly reference variables like var.scc_username.
#
# By storing the necessary data in the 'triggers' map, the values are snapshotted
# in the Terraform state and become accessible to the provisioner via 'self.triggers'
# during the destroy phase.
resource "null_resource" "scc_deregister_cluster_nodes" {
  # Only create this resource if SCC credentials are provided. It runs for each node.
  count = var.scc_username != null && var.scc_password != null ? var.cluster_node_count : 0

  triggers = {
    # The hostname used for registration is the VM's OS hostname, which the boot
    # script sets to match this naming convention via hostnamectl.
    scc_registration_name = "vm-observability-node-${count.index + 1}"
    scc_username          = var.scc_username
    scc_password          = var.scc_password
    script_path           = "${path.module}/deregister-scc.sh"
    # Explicit dependency on the VM resource.
    vm_id = local.cluster_vm_ids[count.index]
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.script_path

    environment = {
      SCC_USERNAME      = self.triggers.scc_username
      SCC_PASSWORD      = self.triggers.scc_password
      REGISTRATION_NAME = self.triggers.scc_registration_name
    }
  }
}

# --- Wait for SUSE Observability ---

# This resource uses a local-exec provisioner to poll the SUSE Observability
# ingress endpoint. It blocks the Terraform apply process until the UI is
# responding, or until it times out. This provides feedback to the user and
# ensures that the deployment is complete when Terraform finishes.
resource "null_resource" "wait_for_observability" {
  # Only run this waiter if at least one node is being created.
  count = var.cluster_node_count > 0 ? 1 : 0

  # Using triggers ensures that this resource is re-evaluated if these values change.
  # It also makes the dependency on the load balancer's IP explicit.
  triggers = {
    # This resource logically depends on the first VM, where SUSE Observability is installed.
    vm_id                  = local.cluster_vm_ids[0]
    observability_hostname = local.observability_hostname
    lb_public_ip           = local.lb_public_ip
    use_letsencrypt        = var.use_letsencrypt
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    # This script polls the SUSE Observability UI using curl.
    # For Let's Encrypt, it performs a strict check, failing if the certificate is not valid.
    # This prevents Terraform from reporting success when the certificate is bad.
    command = <<-EOT
      echo "Waiting for SUSE Observability to become available with a valid certificate at https://${self.triggers.observability_hostname}"
      echo "This can take up to 40 minutes: it starts polling as soon as the instance exists, well before"
      echo "cloud-init finishes RKE2 install, cert-manager, the EBS CSI driver, and the SUSE Observability"
      echo "Helm install/rollout (which itself waits on every pod - OpenSearch, ClickHouse, Kafka, etc. -"
      echo "to become ready). Polling..."
      end_time=$((SECONDS+2400)) # 40 minute timeout

      while [ $SECONDS -lt $end_time ]; do
        # For Let's Encrypt, we perform a strict check. Curl will exit with a non-zero code
        # if the certificate is not trusted by the system's CA store.
        if [ "${self.triggers.use_letsencrypt}" = "true" ]; then
          # The '--fail' flag ensures curl returns an error for HTTP codes like 404 or 503.
          # The lack of '--insecure' ensures curl validates the certificate.
          # We capture stderr to diagnose the specific error.
          curl_error=$(curl --fail --silent --show-error --connect-timeout 10 --resolve ${self.triggers.observability_hostname}:443:${self.triggers.lb_public_ip} https://${self.triggers.observability_hostname}/ 2>&1 >/dev/null)
          if [ $? -eq 0 ]; then
            echo "Successfully connected to SUSE Observability with a valid Let's Encrypt certificate."
            echo "SUSE Observability deployment is ready."
            exit 0
          else
            if [[ "$curl_error" == *"self-signed certificate"* ]]; then
              echo "SUSE Observability is up but is still using a self-signed certificate. Waiting for Let's Encrypt..."
            else
              echo "SUSE Observability not ready yet. Polling check failed: $curl_error. Retrying in 20 seconds..."
            fi
          fi
        else
          # For custom certs, we can only check if the application is responsive,
          # as the CA might not be in the system's trust store.
          https_code=$(curl --resolve ${self.triggers.observability_hostname}:443:${self.triggers.lb_public_ip} --insecure --silent --output /dev/null --write-out "%%{http_code}" https://${self.triggers.observability_hostname}/)
          if [ "$https_code" = "200" ]; then
            echo "SUSE Observability is ready with a custom certificate (HTTPS / returned 200)."
            exit 0
          fi
          echo "SUSE Observability not ready yet (HTTPS / code: $https_code). Retrying in 20 seconds..."
        fi
        sleep 20
      done

      echo "Error: Timed out after 40 minutes waiting for SUSE Observability to become healthy on HTTPS." >&2
      echo "If using Let's Encrypt, this likely means the certificate could not be obtained." >&2
      echo "Please check the cloud-init logs on 'vm-observability-node-1' for errors: 'sudo journalctl -u cloud-final'" >&2
      exit 1
    EOT
  }
}

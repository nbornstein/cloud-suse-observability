#!/usr/bin/env bash
set -x

# 0. Set the OS hostname. SCC registration (next step) records whatever hostname
# is set at registration time, and the de-registration-on-destroy step looks
# systems up by this same name - so it must be set before SUSEConnect runs.
hostnamectl set-hostname "${vm_hostname}"

# 1. Register SLES with SUSE Customer Center
# set +x/-x brackets this so the registration code isn't traced into cloud-init logs.
set +x
SUSEConnect -r "${sles_reg_code}"
set -x

# 2. Kernel & OS prep for RKE2
systemctl stop apparmor || true
systemctl disable apparmor || true

# 3. Create RKE2 config directory
mkdir -p /etc/rancher/rke2

cat <<EOF > /etc/rancher/rke2/config.yaml
token: "${rke2_token}"
tls-san:
  - "${lb_ip}"
  - "${observability_hostname}"
cni:
  - canal
write-kubeconfig-mode: "0640"
ingress-controller:
  - ${rke2_ingress_controller}
EOF

# 4. Install & Start RKE2
# An empty rke2_version is meant to resolve to whatever is on RKE2's "stable"
# channel (see variables.tf), which get.rke2.io would normally resolve itself -
# but its internal resolution issues a HEAD request to update.rke2.io and reads
# back the final redirected URL. That endpoint doesn't reliably redirect HEAD
# requests, so the installer sometimes treats the literal string "stable" as a
# version, which then 404s fetching it from GitHub. Resolve it ourselves from
# update.rke2.io's actual JSON channel list instead - python3 is guaranteed
# present since cloud-init itself depends on it.
RKE2_VERSION="${rke2_version}"
if [[ -z "$RKE2_VERSION" ]]; then
  echo "Resolving RKE2 'stable' channel version from update.rke2.io..."
  for attempt in $(seq 1 10); do
    CHANNELS_JSON=$(curl -sfL https://update.rke2.io/v1-release/channels)
    if [[ $? -eq 0 ]]; then
      RKE2_VERSION=$(echo "$CHANNELS_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(next(c["latest"] for c in data["data"] if c["id"] == "stable"))
')
      [[ -n "$RKE2_VERSION" ]] && break
    fi
    echo "Attempt $attempt/10: failed to resolve RKE2 version from update.rke2.io; retrying in 10s..." >&2
    sleep 10
  done
  if [[ -z "$RKE2_VERSION" ]]; then
    echo "Error: Could not resolve RKE2 'stable' channel version from update.rke2.io after 10 attempts." >&2
    exit 1
  fi
  echo "Resolved RKE2 'stable' channel to version: $RKE2_VERSION"
fi
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$RKE2_VERSION" INSTALL_RKE2_TYPE="server" sh -
systemctl enable rke2-server.service || { echo "Error: rke2-server.service unit not found; RKE2 install likely failed." >&2; exit 1; }
systemctl start rke2-server.service || { echo "Error: rke2-server.service failed to start." >&2; exit 1; }

# 5. Environment setup for kubectl & Helm
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin" >> /etc/profile
echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> /etc/profile

echo "Waiting for RKE2 API server to be ready..."
timeout 180s bash -c 'until kubectl get --raw=/readyz &>/dev/null; do echo "Waiting for API server..."; sleep 5; done' || {
  echo "Error: Timed out waiting for the RKE2 API server to respond on 127.0.0.1:6443." >&2
  echo "--- rke2-server.service status ---" >&2
  systemctl status rke2-server.service --no-pager >&2 || true
  echo "--- rke2-server.service logs (last 100 lines) ---" >&2
  journalctl -u rke2-server.service --no-pager | tail -100 >&2 || true
  exit 1
}

echo "Waiting for core RKE2 components (DNS and Ingress) to be ready..."
# RKE2 deploys its addons (CoreDNS, the ingress controller) asynchronously via
# its own embedded helm-controller, reconciling HelmChart CRs into Jobs that
# run `helm install`. The Deployment/DaemonSet objects below don't necessarily
# exist yet just because the apiserver is ready - `kubectl wait`/`rollout
# status` both fail immediately with NotFound on a resource that hasn't been
# created yet, so retry the whole command until the object shows up.
end_time=$((SECONDS + 300))
until kubectl wait --for=condition=Available deployment/rke2-coredns-rke2-coredns -n kube-system --timeout=10s &>/dev/null; do
  if [ $SECONDS -ge $end_time ]; then
    echo "Error: Timed out waiting for CoreDNS (deployment/rke2-coredns-rke2-coredns) to become available." >&2
    kubectl get deployment -n kube-system >&2 || true
    exit 1
  fi
  echo "Waiting for CoreDNS deployment to exist and become available..."
  sleep 5
done
# RKE2's packaged ingress controller (ingress-nginx, or traefik from v1.36 onward)
# runs as a DaemonSet, not a Deployment, so it has no "Available" condition; wait on
# rollout status instead.
end_time=$((SECONDS + 300))
until kubectl rollout status daemonset/${ingress_daemonset_name} -n kube-system --timeout=10s &>/dev/null; do
  if [ $SECONDS -ge $end_time ]; then
    echo "Error: Timed out waiting for the ingress controller (daemonset/${ingress_daemonset_name}) to become ready." >&2
    kubectl get daemonset -n kube-system >&2 || true
    exit 1
  fi
  echo "Waiting for ingress controller daemonset/${ingress_daemonset_name} to exist and become ready..."
  sleep 5
done
echo "RKE2 core components are ready."

# 6. Install Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -

# 7. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${cert_manager_version}/cert-manager.yaml

echo "Waiting for cert-manager webhook to be ready..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook \
  --namespace cert-manager --timeout=300s
echo "cert-manager webhook is ready."

%{ if use_letsencrypt ~}
echo "Creating Let's Encrypt ClusterIssuer..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${letsencrypt_email}"
    privateKeySecretRef:
      name: letsencrypt-prod-private-key
    solvers:
    - http01:
        ingress:
          ingressClassName: ${ingress_class_name}
EOF
%{ endif ~}

# 8. Install the AWS EBS CSI driver + a default StorageClass.
# Unlike Rancher, SUSE Observability's own services (OpenSearch, ClickHouse,
# Kafka, etc.) need PersistentVolumeClaims to actually bind - plain RKE2 (unlike
# EKS) ships no CSI driver or default StorageClass at all. The instance profile
# granting this driver's pods AWS credentials is attached in iam-aws.tf.
echo "Installing the AWS EBS CSI driver..."
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update
helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --wait --timeout 10m

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
EOF
echo "AWS EBS CSI driver installed; 'gp3' is now the default StorageClass."

# 9. Create the suse-observability namespace and configure its ingress TLS secret.
kubectl create namespace suse-observability --dry-run=client -o yaml | kubectl apply -f -

%{ if !use_letsencrypt ~}
# --- Custom Certificate Configuration ---
echo "Configuring SUSE Observability with custom TLS certificate."

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: tls-observability-ingress
  namespace: suse-observability
type: kubernetes.io/tls
data:
  tls.crt: ${tls_cert_b64}
  tls.key: ${tls_key_b64}
EOF

TLS_SECRET_NAME="tls-observability-ingress"

%{ else ~}
# --- Let's Encrypt Configuration ---
echo "Configuring SUSE Observability with Let's Encrypt."

# Decouple certificate creation from the SUSE Observability install to prevent
# race conditions:
# 1. Wait for observability_hostname to resolve to this load balancer in public DNS.
# 2. Create a Certificate resource manually.
# 3. Wait for cert-manager to issue the certificate and create the secret.
# 4. Install SUSE Observability, telling its ingress to use the pre-existing secret.
wait_for_public_dns() {
  echo "Waiting for ${observability_hostname} to resolve to ${lb_ip} in public DNS before requesting a Let's Encrypt certificate..."
  local end_time=$((SECONDS + 600))
  while [ $SECONDS -lt $end_time ]; do
    resolved_ip=$(curl --silent --max-time 10 "https://dns.google/resolve?name=${observability_hostname}&type=A" \
      | grep -o '"data":"[0-9.]*"' | head -n1 | cut -d'"' -f4)
    if [ "$resolved_ip" = "${lb_ip}" ]; then
      echo "DNS resolution confirmed: ${observability_hostname} -> $resolved_ip"
      return 0
    fi
    echo "DNS not ready yet (got '$${resolved_ip:-<no answer>}', want ${lb_ip}). Retrying in 15s..."
    sleep 15
  done
  return 1
}

if ! wait_for_public_dns; then
  echo "Error: Timed out after 10 minutes waiting for ${observability_hostname} to resolve to ${lb_ip}." >&2
  echo "The Let's Encrypt HTTP-01 challenge requires this to succeed first. Check the DNS record (Route53, sslip.io, or manual) and retry." >&2
  exit 1
fi

echo "Creating Certificate resource to trigger Let's Encrypt..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: observability-tls-cert
  namespace: suse-observability
spec:
  secretName: tls-observability-ingress
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "${observability_hostname}"
EOF

echo "Waiting for Let's Encrypt certificate to be issued... This can take several minutes."
kubectl wait --for=condition=Ready certificate/observability-tls-cert -n suse-observability --timeout=600s || {
  echo "Error: Timed out waiting for the Let's Encrypt certificate 'observability-tls-cert' to become Ready." >&2
  echo "--- cert-manager diagnostics (certificate/observability-tls-cert) ---" >&2
  kubectl describe certificate observability-tls-cert -n suse-observability >&2 || true
  echo "--- cert-manager diagnostics (challenges) ---" >&2
  kubectl get challenges -n suse-observability -o wide >&2 || true
  kubectl describe challenges -n suse-observability >&2 || true
  echo "Refusing to install SUSE Observability against a certificate that was never issued." >&2
  exit 1
}
echo "Certificate 'tls-observability-ingress' has been successfully issued."

TLS_SECRET_NAME="tls-observability-ingress"
%{ endif ~}

# 10. Deploy SUSE Observability via Helm.
echo "Installing SUSE Observability..."
helm repo add suse-observability https://charts.rancher.com/server-charts/prime/suse-observability
helm repo update

# The chart ships a companion "suse-observability-values" helper chart that
# renders the base config/sizing/affinity values for a given license, baseUrl,
# and sizing profile - rather than hand-writing them, render them the same way
# the official docs do:
# https://documentation.suse.com/cloudnative/suse-observability/latest/en/setup/install-stackstate/kubernetes_openshift/kubernetes_install.html
set +x
helm template suse-observability-values suse-observability/suse-observability-values \
  --set license="${suse_observability_license}" \
  --set baseUrl="https://${observability_hostname}" \
  --set sizing.profile="${suse_observability_sizing_profile}" \
  --set adminPassword="${suse_observability_admin_password}" \
  --output-dir /root/suse-observability-values
set -x

CHART_VERSION_OPTS=""
%{ if suse_observability_chart_version != "" ~}
CHART_VERSION_OPTS="--version ${suse_observability_chart_version}"
%{ endif ~}

# Browser clients (e.g. the Rancher UI extension) calling SUSE Observability's
# API cross-origin are rejected unless their origin is explicitly allow-listed -
# without this, the Rancher UI extension fails with "The Rancher host is not
# configured as an allowed origin for SUSE Observability."
ALLOWED_ORIGINS_OPTS=""
%{ if allowed_origins_csv != "" ~}
ALLOWED_ORIGINS_OPTS="--set stackstate.allowedOrigins={${allowed_origins_csv}}"
%{ endif ~}

# SUSE Observability itself never terminates TLS - that's always the ingress
# controller's job (see the README's TLS section) - so the chart's own
# ingress.* values just need pointing at the RKE2-packaged controller and the
# secret populated above.
helm upgrade --install suse-observability suse-observability/suse-observability \
  --namespace suse-observability --create-namespace \
  --values /root/suse-observability-values/suse-observability-values/templates/baseConfig_values.yaml \
  --values /root/suse-observability-values/suse-observability-values/templates/sizing_values.yaml \
  --values /root/suse-observability-values/suse-observability-values/templates/affinity_values.yaml \
  --set ingress.enabled=true \
  --set ingress.ingressClassName=${ingress_class_name} \
  --set ingress.annotations."nginx\.ingress\.kubernetes\.io/proxy-body-size"=50m \
  --set ingress.hosts[0].host="${observability_hostname}" \
  --set ingress.tls[0].hosts[0]="${observability_hostname}" \
  --set ingress.tls[0].secretName="$TLS_SECRET_NAME" \
  $CHART_VERSION_OPTS \
  $ALLOWED_ORIGINS_OPTS \
  --wait --timeout 30m

echo "SUSE Observability Helm release is deployed and all pods report Ready."

# 11. Final health check to confirm the UI is reachable through the ingress
# before the script exits, the same way cloud-rancher confirms Rancher's.
echo "Performing final health check on SUSE Observability..."

health_check_command() {
  %{ if use_letsencrypt ~}
  curl --fail --silent --show-error --connect-timeout 10 --resolve ${observability_hostname}:443:127.0.0.1 https://${observability_hostname}/ > /dev/null
  %{ else ~}
  [[ "$(curl -k --resolve ${observability_hostname}:443:127.0.0.1 -s -o /dev/null -w '%%{http_code}' https://${observability_hostname}/)" == "200" ]]
  %{ endif ~}
}

health_check_end_time=$((SECONDS + 480))
while ! health_check_command; do
  if [ $SECONDS -ge $health_check_end_time ]; then
    echo "Timed out waiting for SUSE Observability to become healthy." >&2
    exit 1
  fi
  echo "Waiting for SUSE Observability to become healthy with a valid certificate..."
  sleep 15
done

echo "SUSE Observability is ready at https://${observability_hostname}"

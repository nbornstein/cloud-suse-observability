#!/usr/bin/env bash
set -x

# 0. Set the OS hostname (see first-node.sh.tpl for why this must come first).
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
server: https://${first_node_ip}:9345
token: "${rke2_token}"
tls-san:
  - "${lb_ip}"
  - "${observability_hostname}"
cni:
  - canal
write-kubeconfig-mode: "0640"
EOF

# 4. Install & Start RKE2 as server (Control-Plane + Etcd + Worker)
# See first-node.sh.tpl for why an empty rke2_version is resolved here rather
# than left to get.rke2.io's own (broken) channel resolution.
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

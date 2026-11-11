#!/usr/bin/env bash
set -e

# This script de-registers a system from the SUSE Customer Center (SCC)
# using its hostname. It's intended to be called by a Terraform
# destroy provisioner.

# It requires the following environment variables to be set:
# - SCC_USERNAME: The username for the SCC account.
# - SCC_PASSWORD: The password for the SCC account.
# - REGISTRATION_NAME: The name of the system to de-register (e.g., a hostname).

if ! command -v jq &> /dev/null; then
    echo "jq could not be found. Please install jq to use SCC de-registration."
    # Exit gracefully so destroy is not blocked
    exit 0
fi

if [[ -z "$SCC_USERNAME" || -z "$SCC_PASSWORD" ]]; then
  echo "SCC_USERNAME and/or SCC_PASSWORD are not set. Skipping de-registration."
  exit 0
fi

if [[ -z "$REGISTRATION_NAME" ]]; then
  echo "REGISTRATION_NAME is not set. Cannot de-register system."
  exit 0
fi

echo "Attempting to de-register system with name: ${REGISTRATION_NAME}"

# 1. Authenticate with SCC and get a token
encoded_username=$(printf %s "$SCC_USERNAME" | jq -s -R -r @uri)
encoded_password=$(printf %s "$SCC_PASSWORD" | jq -s -R -r @uri)

auth_response=$(curl -s -X POST \
  "https://scc.suse.com/connect/v1/session" \
  -d "username=${encoded_username}&password=${encoded_password}")

token=$(echo "$auth_response" | jq -r '.token')

if [[ -z "$token" || "$token" == "null" ]]; then
  echo "Failed to authenticate with SCC. Response: $auth_response. De-registration skipped."
  exit 0
fi

# 2. Find the system ID by hostname
systems_response=$(curl -s -H "Authorization: Bearer ${token}" \
  "https://scc.suse.com/connect/v1/systems?hostname=${REGISTRATION_NAME}")

system_id=$(echo "$systems_response" | jq -r '.data[0].id')

if [[ -z "$system_id" || "$system_id" == "null" ]]; then
  echo "No system found with name '${REGISTRATION_NAME}'. It may have been de-registered already."
  exit 0
fi

echo "Found system with ID: ${system_id} for name: ${REGISTRATION_NAME}. De-registering..."

# 3. De-register the system
http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
  -H "Authorization: Bearer ${token}" \
  "https://scc.suse.com/connect/v1/systems/${system_id}")

if [[ "$http_code" -eq 204 ]]; then
  echo "Successfully de-registered system ID ${system_id}."
else
  echo "Failed to de-register system ID ${system_id}. SCC API returned HTTP ${http_code}."
fi

exit 0

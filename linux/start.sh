#!/bin/bash
set -euo pipefail

print_header() {
  echo -e "\n>>> $1\n"
}

AZP_URL="${AZP_URL:?Environment variable AZP_URL is required (e.g. https://dev.azure.com/your-org)}"
AZP_POOL="${AZP_POOL:-Default}"
AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"
AZP_WORK="${AZP_WORK:-_work}"

# Auth mode: MI (user-assigned managed identity) or SP-OIDC (app registration with federated credential)
AZP_AUTH_TYPE="${AZP_AUTH_TYPE:-MI}"

# Optional flags
AZP_PLACEHOLDER="${AZP_PLACEHOLDER:-}"
AZP_AGENT_ONCE="${AZP_AGENT_ONCE:-}"

# Token is written to disk and re-read on demand, so the bearer token never
# lingers in the environment of the agent or of any pipeline task it runs.
AZP_TOKEN_FILE="${AZP_TOKEN_FILE:-/home/agent/azp-agent/.token}"

# Azure DevOps AAD resource (application) ID — access tokens must be scoped here
ADO_RESOURCE_ID="499b84ac-1321-427f-aa17-267ca6975798"

# Object (principal) ID of the user-assigned managed identity, per the reference guide.
# On Container Apps / App Service / Functions the MSI endpoint accepts object_id.
MANAGED_IDENTITY_OBJECT_ID="${MANAGED_IDENTITY_OBJECT_ID:-}"
# Client ID of the user-assigned managed identity — the only selector IMDS accepts
# (AKS pod identity, ACI, plain VMs/VMSS).
AZP_CLIENT_ID="${AZP_CLIENT_ID:-}"

get_token_managed_identity() {
  local url response token

  if [ -n "${IDENTITY_ENDPOINT:-}" ] && [ -n "${IDENTITY_HEADER:-}" ]; then
    # Platform-injected MSI endpoint (Container Apps, App Service, Functions)
    url="${IDENTITY_ENDPOINT}?api-version=2019-08-01&resource=${ADO_RESOURCE_ID}"
    if [ -n "${MANAGED_IDENTITY_OBJECT_ID}" ]; then
      url="${url}&object_id=${MANAGED_IDENTITY_OBJECT_ID}"
    elif [ -n "${AZP_CLIENT_ID}" ]; then
      url="${url}&client_id=${AZP_CLIENT_ID}"
    fi
    response="$(curl -sS -f "${url}" -H "X-IDENTITY-HEADER: ${IDENTITY_HEADER}")"
  else
    # IMDS (AKS, ACI, VM / VMSS). Only client_id or the full resource ID select a UAMI here.
    url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${ADO_RESOURCE_ID}"
    if [ -n "${AZP_CLIENT_ID}" ]; then
      url="${url}&client_id=${AZP_CLIENT_ID}"
    elif [ -n "${MANAGED_IDENTITY_OBJECT_ID}" ]; then
      url="${url}&object_id=${MANAGED_IDENTITY_OBJECT_ID}"
    fi
    response="$(curl -sS -f -H "Metadata: true" "${url}")"
  fi

  token="$(echo "${response}" | jq -r '.access_token')"
  if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    echo 1>&2 "error: failed to retrieve token for managed identity"
    return 1
  fi
  echo -n "${token}"
}

get_token_sp_oidc() {
  : "${AZP_CLIENT_ID:?AZP_CLIENT_ID is required for SP-OIDC}"
  : "${AZP_TENANT_ID:?AZP_TENANT_ID is required for SP-OIDC}"

  # Federated token (client assertion). Prefer file (AKS workload identity convention),
  # fall back to AZP_CLIENT_ASSERTION env var.
  local assertion="" response token
  if [ -n "${AZURE_FEDERATED_TOKEN_FILE:-}" ] && [ -f "${AZURE_FEDERATED_TOKEN_FILE}" ]; then
    assertion="$(cat "${AZURE_FEDERATED_TOKEN_FILE}")"
  elif [ -n "${AZP_CLIENT_ASSERTION:-}" ]; then
    assertion="${AZP_CLIENT_ASSERTION}"
  else
    echo 1>&2 "error: SP-OIDC requires AZURE_FEDERATED_TOKEN_FILE or AZP_CLIENT_ASSERTION"
    return 1
  fi

  response="$(curl -sS -f -X POST \
    "https://login.microsoftonline.com/${AZP_TENANT_ID}/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${AZP_CLIENT_ID}" \
    --data-urlencode "scope=${ADO_RESOURCE_ID}/.default" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${assertion}" \
    --data-urlencode "grant_type=client_credentials")"

  token="$(echo "${response}" | jq -r '.access_token')"
  if [ -z "${token}" ] || [ "${token}" = "null" ]; then
    echo 1>&2 "error: failed to retrieve token for federated service principal"
    return 1
  fi
  echo -n "${token}"
}

# Acquires a fresh Azure DevOps access token and writes it to AZP_TOKEN_FILE.
write_token_file() {
  local token
  case "${AZP_AUTH_TYPE}" in
    MI)      token="$(get_token_managed_identity)" ;;
    SP-OIDC) token="$(get_token_sp_oidc)" ;;
    *)       echo 1>&2 "error: AZP_AUTH_TYPE must be MI or SP-OIDC"; return 1 ;;
  esac
  ( umask 077 && echo -n "${token}" > "${AZP_TOKEN_FILE}" )
}

cleanup() {
  if [ -n "${TOKEN_REFRESH_PID:-}" ]; then
    kill "${TOKEN_REFRESH_PID}" 2>/dev/null || true
  fi

  if [ -n "${AZP_PLACEHOLDER}" ]; then
    echo 'Running in placeholder mode, skipping cleanup'
    return
  fi

  if [ -e config.sh ] && [ -f .agent ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    # The token acquired at configure time is only valid for ~60 minutes, so
    # always mint a fresh one before unregistering.
    write_token_file || true

    local attempt=1
    while [ "${attempt}" -le 5 ]; do
      ./config.sh remove --unattended --auth PAT --token "$(cat "${AZP_TOKEN_FILE}")" && break
      echo "Retrying in 30 seconds... (attempt ${attempt}/5)"
      attempt=$((attempt + 1))
      sleep 30
    done
  fi

  rm -f "${AZP_TOKEN_FILE}"
}
trap cleanup EXIT SIGTERM SIGINT

print_header "Acquiring Azure DevOps access token (auth: ${AZP_AUTH_TYPE})..."
write_token_file

if [ ! -f .agent ]; then
  print_header "Configuring Azure Pipelines agent..."
  ./config.sh \
    --unattended \
    --url "${AZP_URL}" \
    --auth PAT \
    --token "$(cat "${AZP_TOKEN_FILE}")" \
    --pool "${AZP_POOL}" \
    --agent "${AZP_AGENT_NAME}" \
    --work "${AZP_WORK}" \
    --replace \
    --acceptTeeEula
else
  echo "Agent already configured, skipping config."
fi

if [ -n "${AZP_PLACEHOLDER}" ]; then
  print_header "Placeholder mode: agent registered, not starting the listener."
  exit 0
fi

# Keep AZP_TOKEN_FILE holding a valid token so cleanup can always unregister,
# even for agents that outlive the 60-minute token lifetime.
(
  while true; do
    sleep 2700
    write_token_file || echo 1>&2 "warning: token refresh failed, will retry"
  done
) &
TOKEN_REFRESH_PID=$!

print_header "Starting Azure Pipelines agent..."
if [ -n "${AZP_AGENT_ONCE}" ]; then
  # Ephemeral agent: run a single job, then exit so cleanup unregisters it.
  ./run.sh --once & wait $!
else
  ./run.sh & wait $!
fi

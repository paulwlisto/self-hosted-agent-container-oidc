#!/bin/bash
set -euo pipefail

AZP_URL="${AZP_URL:?Environment variable AZP_URL is required (e.g. https://dev.azure.com/your-org)}"
AZP_POOL="${AZP_POOL:-Default}"
AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"

# Auth mode: MI (managed identity) or SP-OIDC (app registration with federated credential)
AZP_AUTH_TYPE="${AZP_AUTH_TYPE:?Environment variable AZP_AUTH_TYPE is required (MI or SP-OIDC)}"

# Azure DevOps AAD resource (application) ID — access tokens must be scoped here
ADO_RESOURCE_ID="499b84ac-1321-427f-aa17-267ca6975798"

get_token_managed_identity() {
  # AZP_CLIENT_ID optional — if set, used to target a specific user-assigned MI
  local imds_url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=${ADO_RESOURCE_ID}"
  if [ -n "${AZP_CLIENT_ID:-}" ]; then
    imds_url="${imds_url}&client_id=${AZP_CLIENT_ID}"
  fi
  curl -sS -f -H "Metadata: true" "${imds_url}" | jq -r '.access_token'
}

get_token_sp_oidc() {
  : "${AZP_CLIENT_ID:?AZP_CLIENT_ID is required for SP-OIDC}"
  : "${AZP_TENANT_ID:?AZP_TENANT_ID is required for SP-OIDC}"

  # Federated token (client assertion). Prefer file (AKS workload identity convention),
  # fall back to AZP_CLIENT_ASSERTION env var.
  local assertion=""
  if [ -n "${AZURE_FEDERATED_TOKEN_FILE:-}" ] && [ -f "${AZURE_FEDERATED_TOKEN_FILE}" ]; then
    assertion="$(cat "${AZURE_FEDERATED_TOKEN_FILE}")"
  elif [ -n "${AZP_CLIENT_ASSERTION:-}" ]; then
    assertion="${AZP_CLIENT_ASSERTION}"
  else
    echo "ERROR: SP-OIDC requires AZURE_FEDERATED_TOKEN_FILE or AZP_CLIENT_ASSERTION" >&2
    exit 1
  fi

  curl -sS -f -X POST \
    "https://login.microsoftonline.com/${AZP_TENANT_ID}/oauth2/v2.0/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${AZP_CLIENT_ID}" \
    --data-urlencode "scope=${ADO_RESOURCE_ID}/.default" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion=${assertion}" \
    --data-urlencode "grant_type=client_credentials" \
    | jq -r '.access_token'
}

azure_cli_login() {
  case "${AZP_AUTH_TYPE}" in
    MI)
      echo "Logging in to Azure CLI with managed identity..."
      if [ -n "${AZP_CLIENT_ID:-}" ]; then
        az login --identity --client-id "${AZP_CLIENT_ID}" --output none
      else
        az login --identity --output none
      fi
      ;;
    SP-OIDC)
      echo "Logging in to Azure CLI with federated credential..."
      local assertion_file="${AZURE_FEDERATED_TOKEN_FILE:-}"
      if [ -z "${assertion_file}" ] && [ -n "${AZP_CLIENT_ASSERTION:-}" ]; then
        assertion_file="$(mktemp)"
        printf '%s' "${AZP_CLIENT_ASSERTION}" > "${assertion_file}"
      fi
      az login --service-principal \
        --username "${AZP_CLIENT_ID}" \
        --tenant "${AZP_TENANT_ID}" \
        --federated-token "$(cat "${assertion_file}")" \
        --output none
      ;;
    *)
      echo "ERROR: AZP_AUTH_TYPE must be MI or SP-OIDC (got: ${AZP_AUTH_TYPE})" >&2
      exit 1
      ;;
  esac
}

echo "Acquiring Azure DevOps access token (auth: ${AZP_AUTH_TYPE})..."
case "${AZP_AUTH_TYPE}" in
  MI)      AZP_TOKEN="$(get_token_managed_identity)" ;;
  SP-OIDC) AZP_TOKEN="$(get_token_sp_oidc)" ;;
  *)       echo "ERROR: AZP_AUTH_TYPE must be MI or SP-OIDC" >&2; exit 1 ;;
esac

if [ -z "${AZP_TOKEN}" ] || [ "${AZP_TOKEN}" = "null" ]; then
  echo "ERROR: failed to acquire Azure DevOps access token" >&2
  exit 1
fi

azure_cli_login

if [ ! -f .agent ]; then
  echo "Configuring agent..."
  ./config.sh \
    --unattended \
    --url "${AZP_URL}" \
    --auth pat \
    --token "${AZP_TOKEN}" \
    --pool "${AZP_POOL}" \
    --agent "${AZP_AGENT_NAME}" \
    --replace \
    --acceptTeeEula
else
  echo "Agent already configured, skipping config."
fi

cleanup() {
  if [ -f .agent ]; then
    echo "Removing agent..."
    # Refresh token — the original may have expired during the agent's lifetime
    local remove_token
    case "${AZP_AUTH_TYPE}" in
      MI)      remove_token="$(get_token_managed_identity)" ;;
      SP-OIDC) remove_token="$(get_token_sp_oidc)" ;;
    esac
    ./config.sh remove \
      --auth pat \
      --token "${remove_token}" || true
  fi
}
trap cleanup SIGTERM SIGINT

echo "Starting agent..."
exec ./run.sh

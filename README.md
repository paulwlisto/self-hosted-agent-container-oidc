# Self-Hosted Agent Container

An Azure DevOps self-hosted agent container image pre-loaded with common DevOps tools. Publishes to Azure Container Registry (ACR) on tag push.

## Included Tools

- Azure CLI (`az`) + Bicep
- .NET SDK 8.0
- Terraform
- Packer
- Helm
- kubectl
- Docker CLI
- ORAS CLI
- tfsec, trivy, checkov
- Node.js + npm
- Git, curl, wget, jq, unzip

## Usage

### Prerequisites

Either a **Managed Identity** (system- or user-assigned) or an **App Registration with a federated credential** (OIDC) is required. Whichever you pick must be:

1. Added as a user in your Azure DevOps organization (`<app-id>@<tenant-id>` for SP, or the MI's object ID)
2. Granted **Agent Pool Administrator** on the target pool

Secret-based service principal auth is not supported — the container authenticates to Azure DevOps using an AAD access token acquired via OIDC.

### Environment Variables

#### Common (both auth modes)

| Variable         | Required | Description                                                           |
| ---------------- | -------- | --------------------------------------------------------------------- |
| `AZP_URL`        | Yes      | Azure DevOps organization URL (e.g. `https://dev.azure.com/your-org`) |
| `AZP_AUTH_TYPE`  | Yes      | `MI` for managed identity, `SP-OIDC` for federated service principal  |
| `AZP_POOL`       | No       | Agent pool name (defaults to `Default`)                               |
| `AZP_AGENT_NAME` | No       | Agent name (defaults to container hostname)                           |

#### `AZP_AUTH_TYPE=MI` — Managed Identity

Intended for containers running on Azure hosts that expose IMDS (AKS with MI enabled, Azure Container Apps, Azure Container Instances, Azure VMs).

| Variable        | Required    | Description                                                                                           |
| --------------- | ----------- | ----------------------------------------------------------------------------------------------------- |
| `AZP_CLIENT_ID` | Conditional | Client ID of a **user-assigned** managed identity. Omit for the host's **system-assigned** identity. |

#### `AZP_AUTH_TYPE=SP-OIDC` — App Registration with Federated Credential

Intended for AKS Workload Identity, GitHub Actions, or any environment that can project an OIDC token for the app registration.

| Variable                     | Required    | Description                                                                                     |
| ---------------------------- | ----------- | ----------------------------------------------------------------------------------------------- |
| `AZP_CLIENT_ID`              | Yes         | App registration (client) ID                                                                    |
| `AZP_TENANT_ID`              | Yes         | Microsoft Entra ID tenant ID                                                                    |
| `AZURE_FEDERATED_TOKEN_FILE` | Conditional | Path to a file containing the OIDC client assertion (set automatically by AKS Workload Identity) |
| `AZP_CLIENT_ASSERTION`       | Conditional | OIDC client assertion as a string. Used only if `AZURE_FEDERATED_TOKEN_FILE` is not set         |

One of `AZURE_FEDERATED_TOKEN_FILE` or `AZP_CLIENT_ASSERTION` must be provided.

### Run the container

**Managed identity (user-assigned):**

```bash
docker run -d \
  -e AZP_URL=https://dev.azure.com/your-org \
  -e AZP_AUTH_TYPE=MI \
  -e AZP_CLIENT_ID=<user-assigned-mi-client-id> \
  -e AZP_POOL=Default \
  -e AZP_AGENT_NAME=my-agent \
  your-acr.azurecr.io/self-hosted-agent:latest
```

**Service principal with federated credential (OIDC):**

```bash
docker run -d \
  -e AZP_URL=https://dev.azure.com/your-org \
  -e AZP_AUTH_TYPE=SP-OIDC \
  -e AZP_CLIENT_ID=<app-registration-client-id> \
  -e AZP_TENANT_ID=<entra-tenant-id> \
  -e AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token \
  -e AZP_POOL=Default \
  -e AZP_AGENT_NAME=my-agent \
  your-acr.azurecr.io/self-hosted-agent:latest
```

### App Registration (SP-OIDC) Setup

1. Create an App Registration in Microsoft Entra ID
2. Under **Certificates & secrets → Federated credentials**, add a credential for your workload (e.g. AKS Workload Identity, GitHub Actions)
3. In Azure DevOps, add the SP as a user (`<app-id>@<tenant-id>`) with access to the target agent pool
4. Grant the SP **Agent Pool Administrator** on the pool

### Managed Identity Setup

1. Assign a system- or user-assigned MI to the Azure host running the container
2. In Azure DevOps, add the MI as a user with access to the target agent pool
3. Grant the MI **Agent Pool Administrator** on the pool

## Building Locally

```bash
docker build -t self-hosted-agent -f linux/Dockerfile .
```

The build automatically pulls the latest Azure Pipelines agent release from GitHub.

## Publishing

The image is automatically built and pushed to ACR when a version tag (e.g. `v1.0.0`) is pushed. The Azure Pipelines pipeline requires two variables:

| Pipeline Variable          | Description                                      |
| -------------------------- | ------------------------------------------------ |
| `ACR_NAME`                 | Name of your Azure Container Registry            |
| `AZURE_SERVICE_CONNECTION` | Name of the Azure service connection in the project |

# Self-Hosted Agent Container

An Azure DevOps self-hosted agent container image pre-loaded with common DevOps tools, published to GitHub Container Registry.

```bash
docker pull ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.5
```

Authentication follows the pattern described in [Azure DevOps agents using managed identities](https://www.huuhka.net/azure-devops-agents-using-managed-identitites/): the container acquires a Microsoft Entra ID access token for the Azure DevOps resource (`499b84ac-1321-427f-aa17-267ca6975798`) and passes it to `config.sh` as `--auth PAT`. No secrets or PATs are stored anywhere.

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
- Python 3.11
- Git, curl, wget, jq, unzip

## Usage

### Prerequisites

A **user-assigned managed identity** (recommended) or an **app registration with a federated credential** (OIDC). Whichever you pick must be granted, in Azure DevOps:

1. A **Basic** license — add the identity as a user in the organization
   - Managed identity: search for it by name in **Organization settings → Users → Add users**
   - App registration: add it as `<app-id>@<tenant-id>`
2. Organization-level **Read & manage agent pools** permission (Organization settings → Agent pools → Security)
3. **Administrator** role on the target agent pool

Project-level permissions are not required. Secret-based service principal auth is not supported.

### Environment Variables

#### Common

| Variable          | Required | Default                | Description                                                                       |
| ----------------- | -------- | ---------------------- | --------------------------------------------------------------------------------- |
| `AZP_URL`         | Yes      | —                      | Azure DevOps organization URL (e.g. `https://dev.azure.com/your-org`)             |
| `AZP_AUTH_TYPE`   | No       | `MI`                   | `MI` for managed identity, `SP-OIDC` for federated app registration               |
| `AZP_POOL`        | No       | `Default`              | Agent pool name                                                                   |
| `AZP_AGENT_NAME`  | No       | container hostname     | Agent name as it appears in the pool                                              |
| `AZP_WORK`        | No       | `_work`                | Agent working directory                                                           |
| `AZP_TOKEN_FILE`  | No       | `.../azp-agent/.token` | Where the acquired access token is cached (mode `0600`)                           |
| `AZP_PLACEHOLDER` | No       | unset                  | If non-empty, register the agent and exit without starting it or removing it       |
| `AZP_AGENT_ONCE`  | No       | unset                  | If non-empty, run `run.sh --once`: process a single job, then exit and unregister |

#### `AZP_AUTH_TYPE=MI` — User-Assigned Managed Identity

The identity selector depends on which metadata endpoint the host exposes. The start script detects this automatically.

| Variable                     | Required    | Description                                                                                                                                       |
| ---------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MANAGED_IDENTITY_OBJECT_ID` | Conditional | **Object (principal) ID** of the user-assigned MI. Used against the platform MSI endpoint (Container Apps, App Service, Functions).                 |
| `AZP_CLIENT_ID`              | Conditional | **Client ID** of the user-assigned MI. Required when the token comes from IMDS (AKS, ACI, VM, VMSS) — IMDS does not accept an object ID reliably.  |
| `IDENTITY_ENDPOINT`          | Injected    | Set by the hosting platform. When present (with `IDENTITY_HEADER`), the MSI endpoint is used with `api-version=2019-08-01`.                        |
| `IDENTITY_HEADER`            | Injected    | Set by the hosting platform. Sent as `X-IDENTITY-HEADER`.                                                                                          |

Setting both `MANAGED_IDENTITY_OBJECT_ID` and `AZP_CLIENT_ID` is safe and makes the image portable across both host types.

If neither is set, the host's **system-assigned** identity is used.

#### `AZP_AUTH_TYPE=SP-OIDC` — App Registration with Federated Credential

For AKS Workload Identity, GitHub Actions, or any environment that can project an OIDC token for the app registration.

| Variable                     | Required    | Description                                                                                     |
| ---------------------------- | ----------- | ----------------------------------------------------------------------------------------------- |
| `AZP_CLIENT_ID`              | Yes         | App registration (client) ID                                                                    |
| `AZP_TENANT_ID`              | Yes         | Microsoft Entra ID tenant ID                                                                    |
| `AZURE_FEDERATED_TOKEN_FILE` | Conditional | Path to a file containing the OIDC client assertion (set automatically by AKS Workload Identity) |
| `AZP_CLIENT_ASSERTION`       | Conditional | OIDC client assertion as a string. Used only if `AZURE_FEDERATED_TOKEN_FILE` is not set          |

One of `AZURE_FEDERATED_TOKEN_FILE` or `AZP_CLIENT_ASSERTION` must be provided.

### Token Lifetime

Entra ID access tokens are valid for roughly 60 minutes. The start script:

- writes the token to `AZP_TOKEN_FILE` (mode `0600`) and reads it back on demand, so the bearer token is never left in the environment inherited by pipeline tasks;
- refreshes the token file every 45 minutes in the background;
- mints a **fresh** token during shutdown before calling `config.sh remove`, retrying up to 5 times, so an agent that lived longer than its original token still unregisters cleanly.

For long-lived agents, prefer ephemeral agents (`AZP_AGENT_ONCE=1`) with a scaler such as Container Apps jobs or KEDA — each job gets a fresh token and a clean workspace.

### Run the container

**User-assigned managed identity on Azure Container Apps / App Service** (platform injects `IDENTITY_ENDPOINT` and `IDENTITY_HEADER`):

```bash
docker run -d \
  -e AZP_URL=https://dev.azure.com/your-org \
  -e AZP_AUTH_TYPE=MI \
  -e MANAGED_IDENTITY_OBJECT_ID=<user-assigned-mi-object-id> \
  -e AZP_POOL=container-apps \
  -e AZP_AGENT_NAME=my-agent \
  ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.5
```

**User-assigned managed identity on AKS / ACI / a VM** (token comes from IMDS):

```bash
docker run -d \
  -e AZP_URL=https://dev.azure.com/your-org \
  -e AZP_AUTH_TYPE=MI \
  -e AZP_CLIENT_ID=<user-assigned-mi-client-id> \
  -e AZP_POOL=container-apps \
  -e AZP_AGENT_NAME=my-agent \
  ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.5
```

**Ephemeral (single-job) agent:**

```bash
docker run --rm \
  -e AZP_URL=https://dev.azure.com/your-org \
  -e AZP_AUTH_TYPE=MI \
  -e MANAGED_IDENTITY_OBJECT_ID=<user-assigned-mi-object-id> \
  -e AZP_CLIENT_ID=<user-assigned-mi-client-id> \
  -e AZP_AGENT_ONCE=1 \
  ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.5
```

**Service principal with federated credential (OIDC):**

```bash
docker run -d \
  -e AZP_URL=https://dev.azure.com/your-org \
  -e AZP_AUTH_TYPE=SP-OIDC \
  -e AZP_CLIENT_ID=<app-registration-client-id> \
  -e AZP_TENANT_ID=<entra-tenant-id> \
  -e AZURE_FEDERATED_TOKEN_FILE=/var/run/secrets/azure/tokens/azure-identity-token \
  -e AZP_POOL=container-apps \
  -e AZP_AGENT_NAME=my-agent \
  ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.5
```

### User-Assigned Managed Identity Setup

1. Create the user-assigned managed identity and note both its **client ID** and **object (principal) ID**.
2. Assign it to the host running the container (Container App, App Service, AKS node pool / pod identity, ACI, or VM).
3. In Azure DevOps, add the identity as a user with a **Basic** license.
4. Grant it organization-level **Read & manage agent pools**, and **Administrator** on the target pool.
5. Pass `MANAGED_IDENTITY_OBJECT_ID` (MSI endpoint hosts) and/or `AZP_CLIENT_ID` (IMDS hosts).

### App Registration (SP-OIDC) Setup

1. Create an App Registration in Microsoft Entra ID.
2. Under **Certificates & secrets → Federated credentials**, add a credential for your workload (e.g. AKS Workload Identity, GitHub Actions).
3. In Azure DevOps, add the SP as a user (`<app-id>@<tenant-id>`) with a **Basic** license.
4. Grant it organization-level **Read & manage agent pools**, and **Administrator** on the target pool.

## Running on Azure Container Apps Jobs

This is the recommended way to run the image: agents scale from zero, each pipeline job gets a clean container, and nothing is billed while the pool is idle.

The Azure CLI samples below are **guidance** — they show the settings that matter and why. Translate them into your Bicep modules rather than running them as a deployment pipeline.

### How the scaling works

There is **no manager container to deploy**. The Container Apps control plane runs the KEDA `azure-pipelines` scaler for you: every `pollingInterval` seconds it calls the Azure DevOps REST API, counts queued job requests for the pool, and starts one job execution per queued request up to `maxExecutions`.

The full sequence:

1. A pipeline queues a job against the pool.
2. Azure DevOps validates the job's demands against the **placeholder agent's** registered capabilities and leaves the request queued, waiting for an agent to come online.
3. KEDA's next poll sees one queued request and starts a Container Apps job execution.
4. The container acquires a token via the managed identity, registers as a new online agent, and picks up the queued job.
5. `AZP_AGENT_ONCE=1` makes it exit after that one job; the shutdown trap unregisters the agent.

### Why the placeholder agent is required

Azure DevOps will not schedule against a pool with **zero** registered agents — the pipeline fails outright with *"no agent found in pool that satisfies the specified demands"* rather than waiting. Demands are matched against the capabilities that registered agents advertise, and an empty pool has nothing to match.

The fix is to run the image once with `AZP_PLACEHOLDER=1`, which registers an agent and exits without starting the listener. It stays in the pool permanently as **Offline**, consumes no Container Apps or Azure DevOps resources, and gives the scheduler something to validate against.

Two things to keep in mind:

- **Register the placeholder from this same image.** Its capability list is what demands are checked against. A placeholder built from a stock agent image will cause pipelines with `demands: terraform` (or `python3.11`, `checkov`, …) to be rejected before KEDA ever sees them. Re-register it whenever the image gains or loses tooling.
- **Keep agent names distinct.** Pin the placeholder to a fixed name; real agents should default to the container hostname, which is unique per replica. Since `start.sh` passes `--replace`, a real agent sharing the placeholder's name would take over its registration and break the pool.

### Sample: identity and environment

```bash
RESOURCE_GROUP="rg-azdo-agents"
LOCATION="australiaeast"
ENVIRONMENT="cae-azdo-agents"
IDENTITY_NAME="id-azdo-agent"
IMAGE="ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.5"
AZP_URL="https://dev.azure.com/your-org"   # no trailing slash
AZP_POOL="container-apps"

# --scale-rule-identity is a preview feature, so the preview extension is needed
az extension add --name containerapp --upgrade --allow-preview true

az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

az containerapp env create \
  --name "$ENVIRONMENT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION"

az identity create --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP"
```

Capture all three identity IDs — each is used for a different purpose:

```bash
IDENTITY_CLIENT_ID=$(az identity show -n "$IDENTITY_NAME" -g "$RESOURCE_GROUP" --query clientId -o tsv)
IDENTITY_OBJECT_ID=$(az identity show -n "$IDENTITY_NAME" -g "$RESOURCE_GROUP" --query principalId -o tsv)
IDENTITY_RESOURCE_ID=$(az identity show -n "$IDENTITY_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
```

| ID          | Used for                                                        |
| ----------- | --------------------------------------------------------------- |
| Object ID   | `MANAGED_IDENTITY_OBJECT_ID` — token request to the MSI endpoint |
| Client ID   | `AZP_CLIENT_ID` — token request via IMDS                         |
| Resource ID | `--mi-user-assigned` and `--scale-rule-identity`                 |

Then grant the identity access in Azure DevOps. This can't be scripted reliably, so do it in the web UI:

1. **Organization settings → Users → Add users** — add the identity by name, access level **Basic**, granting access to the project that owns the pool.
2. **Organization settings → Agent pools → Security** — grant it **Read & manage** at the organization level.
3. **Organization settings → Agent pools → `<pool>` → Security** — add it with the **Administrator** role.

The same identity is used twice: the agent container registers with the pool, and the KEDA scale rule reads the pool's job queue. Both need the permissions above.

### Sample: register the placeholder agent

A Manual-trigger job, run once. Delete the job afterwards if you like — the agent registration survives independently.

```bash
az containerapp job create \
  --name "azdo-agent-placeholder" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENVIRONMENT" \
  --trigger-type Manual \
  --replica-timeout 300 \
  --replica-retry-limit 0 \
  --replica-completion-count 1 \
  --parallelism 1 \
  --image "$IMAGE" \
  --cpu "2.0" --memory "4Gi" \
  --mi-user-assigned "$IDENTITY_RESOURCE_ID" \
  --env-vars \
    "AZP_URL=$AZP_URL" \
    "AZP_POOL=$AZP_POOL" \
    "AZP_AUTH_TYPE=MI" \
    "MANAGED_IDENTITY_OBJECT_ID=$IDENTITY_OBJECT_ID" \
    "AZP_CLIENT_ID=$IDENTITY_CLIENT_ID" \
    "AZP_AGENT_NAME=placeholder-agent" \
    "AZP_PLACEHOLDER=1"

az containerapp job start --name "azdo-agent-placeholder" --resource-group "$RESOURCE_GROUP"
```

Confirm it succeeded, then check **Agent pools → `<pool>` → Agents** shows `placeholder-agent` as **Offline**:

```bash
az containerapp job execution list \
  --name "azdo-agent-placeholder" --resource-group "$RESOURCE_GROUP" --output table \
  --query '[].{Status:properties.status, Name:name, Start:properties.startTime}'
```

If the package on GHCR is private, add registry credentials with a `read:packages` token:

```bash
  --registry-server ghcr.io \
  --registry-username "<github-user>" \
  --registry-password "<github-pat>"
```

### Sample: the event-driven agent job

```bash
az containerapp job create \
  --name "azdo-agent" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENVIRONMENT" \
  --trigger-type Event \
  --replica-timeout 3600 \
  --replica-retry-limit 0 \
  --replica-completion-count 1 \
  --parallelism 1 \
  --image "$IMAGE" \
  --cpu "2.0" --memory "4Gi" \
  --min-executions 0 \
  --max-executions 10 \
  --polling-interval 30 \
  --scale-rule-name "azure-pipelines" \
  --scale-rule-type "azure-pipelines" \
  --scale-rule-metadata \
    "poolName=$AZP_POOL" \
    "organizationURL=$AZP_URL" \
    "targetPipelinesQueueLength=1" \
  --scale-rule-identity "$IDENTITY_RESOURCE_ID" \
  --mi-user-assigned "$IDENTITY_RESOURCE_ID" \
  --env-vars \
    "AZP_URL=$AZP_URL" \
    "AZP_POOL=$AZP_POOL" \
    "AZP_AUTH_TYPE=MI" \
    "MANAGED_IDENTITY_OBJECT_ID=$IDENTITY_OBJECT_ID" \
    "AZP_CLIENT_ID=$IDENTITY_CLIENT_ID" \
    "AZP_AGENT_ONCE=1"
```

Notable settings:

| Setting                             | Why                                                                                   |
| ----------------------------------- | ------------------------------------------------------------------------------------- |
| `--min-executions 0`                | Scale to zero — no cost while the pool is idle                                        |
| `--replica-retry-limit 0`           | A failed pipeline job is Azure DevOps' problem to retry, not the container's           |
| `--replica-timeout 3600`            | Hard cap on a single pipeline job; raise if your pipelines run longer                  |
| `AZP_AGENT_ONCE=1`                  | One pipeline job per container, then exit and unregister                               |
| `--scale-rule-identity`             | Scaler authenticates with the managed identity instead of a stored PAT                 |
| `--mi-user-assigned`                | Assigns the identity to the replica, which is what injects `IDENTITY_ENDPOINT`         |

Rolling onto a new tag later only needs the image swapped; in-flight executions finish on the old image:

```bash
az containerapp job update --name "azdo-agent" --resource-group "$RESOURCE_GROUP" \
  --image "ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.6"
```

Re-register the placeholder as well when the new image adds or removes tooling that pipelines declare as demands.

### Scale rule authentication

The Microsoft tutorial wires the scale rule up with a PAT, which would reintroduce the secret the managed identity setup removes. `--scale-rule-identity` uses the same user-assigned identity for both the agent registration and the pool-queue polling, so no secret is stored on the job.

Two caveats:

- It is a **preview** feature — hence `az extension add --allow-preview true` above, and API version `2024-02-02-preview` or later in Bicep.
- Managed identity for scale rules is most thoroughly documented for the Azure-resource scalers (Queue Storage, Service Bus, Event Hubs); `azure-pipelines` support arrived via that preview API. Verify it in your subscription. If the scaler can't authenticate, the fallback is a PAT scoped to *Agent Pools (Read & manage)* used **only** by the scale rule, with the agent container itself still fully managed-identity based:

  ```bash
    --secrets "azp-pat=$PAT" "azp-url=$AZP_URL" \
    --scale-rule-auth "personalAccessToken=azp-pat" "organizationURL=azp-url"
  ```

### Limitations of ACA-hosted agents

- **No Docker-in-Docker.** Container Apps cannot run a Docker daemon, so pipeline steps calling `docker build` or `docker run` will fail even though the image ships the Docker CLI. Use `az acr build` (included in the image) for container builds, or host those agents on AKS instead.
- **`--replica-timeout` caps job duration.** A pipeline job exceeding it has its replica killed mid-run.
- **The placeholder must not be deleted.** Removing it from the pool breaks scheduling for the whole pool.

### Troubleshooting

```bash
# Confirm the scale rule was deployed as expected
az containerapp job show --name "azdo-agent" --resource-group "$RESOURCE_GROUP" \
  --query 'properties.configuration.eventTriggerConfig.scale.rules[0]'

# List executions
az containerapp job execution list --name "azdo-agent" --resource-group "$RESOURCE_GROUP" --output table
```

Common causes, in rough order of likelihood:

| Symptom                                                 | Cause                                                                                  |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Pipeline fails immediately, "no agent found in pool"     | Placeholder agent missing, or its capabilities don't satisfy the pipeline's demands     |
| Pipeline queues forever, zero executions                 | Scale rule can't authenticate — identity lacks org-level **Read & manage agent pools** |
| Executions start but the agent never appears in the pool | Identity lacks **Administrator** on the pool, or has no Basic license                   |
| Image pull failure, execution fails instantly            | GHCR package is private and no registry credentials were supplied                       |
| Trailing `/` on `AZP_URL`                                | Breaks both agent registration and the scaler — remove it                               |

## Building Locally

```bash
docker build -t self-hosted-agent -f linux/Dockerfile .
```

The build automatically pulls the latest Azure Pipelines agent release from GitHub.

## Publishing

[`.github/workflows/publish-image.yml`](.github/workflows/publish-image.yml) builds and pushes to GitHub Container Registry when a **GitHub release is published**. It tags the image with the release's semver version and moves `latest`, authenticating with the workflow's built-in `GITHUB_TOKEN` — no secrets to configure.

To cut a new version:

```bash
gh release create 0.0.5 --title 0.0.5 --notes "Managed identity token acquisition via the platform MSI endpoint"
```

The image then becomes available as:

```
ghcr.io/paulwlisto/self-hosted-agent-container-oidc:0.0.5
ghcr.io/paulwlisto/self-hosted-agent-container-oidc:latest
```

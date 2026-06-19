# `webapp/` — Foundry agent chat front end (in-repo)

A small, self-hosted chat web app for the Foundry agent built in
[docs/03d](../docs/03d-foundry-agent-setup.md). It deploys with this repo's own flow —
Bicep for the platform, PowerShell for the build/deploy — and supports per-user identity
passthrough (OBO) so the **Microsoft Fabric data agent tool** enforces row-/object-level
security per user.

This is **not** a fork of any sample. It is a minimal app maintained here so the whole
pattern deploys from a single source.

## Layout

| Path | Purpose |
|---|---|
| [`app/main.py`](./app/main.py) | FastAPI app: relays a message to the agent (MI or OBO identity) and returns the reply. |
| [`app/static/index.html`](./app/static/index.html) | Minimal chat UI (no build step). |
| [`app/Dockerfile`](./app/Dockerfile) · [`app/requirements.txt`](./app/requirements.txt) | Image built from source in Azure Container Registry. |
| [`.env.example`](./.env.example) | Runtime environment reference (placeholders only). |

## Deploy

The hosting platform (Container Apps environment, ACR, Log Analytics, managed identity) is
provisioned by the main Bicep deployment when `deployWebApp = true`; the app is built and
deployed by [`scripts/deploy-webapp.ps1`](../scripts/deploy-webapp.ps1):

```pwsh
# 1. Provision the platform with the base deploy (set deployWebApp = true in your params)
pwsh ./infra/deploy.ps1 -ParameterFile infra/main.parameters.local.json

# 2. Build + deploy the app against your 03d agent
pwsh ./scripts/deploy-webapp.ps1 -FoundryProjectEndpoint $endpoint -AgentId $agentId            # MI mode
pwsh ./scripts/deploy-webapp.ps1 -FoundryProjectEndpoint $endpoint -AgentId $agentId -EnableObo # Fabric tool
```

Full runbook, RBAC, and validation: **[docs/09-foundry-agent-webapp.md](../docs/09-foundry-agent-webapp.md)**.

## Run locally (optional)

```pwsh
cd webapp/app
pip install -r requirements.txt
# Set FOUNDRY_PROJECT_ENDPOINT, AGENT_ID, AZURE_CLIENT_ID (see ../.env.example) in your shell.
# MI mode uses DefaultAzureCredential, which falls back to your `az login` identity locally.
uvicorn main:app --reload
```

OBO mode is an Azure-only scenario (it depends on Container Apps authentication and a
federated managed identity), so run locally in MI mode.

## No real data / no secrets

The image carries no tenant identifiers, subscription IDs, endpoints, or secrets — all are
supplied at runtime. `.env.example` ships with placeholders only; keep any populated `.env`
local.

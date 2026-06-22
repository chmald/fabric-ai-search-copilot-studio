# 09 — Standalone web app front end (in-repo, Azure Container Apps)

This document covers the **self-hosted chat front end** included in this repository at
[`webapp/app/`](../webapp/app/). It is a third way to reach the Foundry agent built in
[03d](./03d-foundry-agent-setup.md) — alongside the Copilot Studio combined channel
([03c](./03c-copilot-studio-setup.md)) and the M365/Teams custom engine agent
([03d Phase D6](./03d-foundry-agent-setup.md#phase-d6--publish-to-microsoft-365-copilot--teams-preview)).

The web app is **part of this repo and deploys with the same flow as the rest of the
pattern**: Bicep for the platform, a PowerShell script for the build and deploy. There is
no second toolchain, and nothing is scaffolded outside the repo.

> **Single source.** Everything needed to stand up the web app lives here:
> the app ([`webapp/app/`](../webapp/app/)), the platform module
> ([`infra/modules/containerapp.bicep`](../infra/modules/containerapp.bicep), gated by the
> `deployWebApp` parameter), and the deploy script
> ([`scripts/deploy-webapp.ps1`](../scripts/deploy-webapp.ps1)). The container image is
> built from source in Azure Container Registry — no local Docker required.

---

## What it is

A minimal **FastAPI** app that relays a user message to the published agent and returns
the reply. No database, no session store, no extra services. It supports two identity
modes and runs on **Azure Container Apps**.

| Piece | Location | Role |
|---|---|---|
| App (container) | [`webapp/app/`](../webapp/app/) | FastAPI + a small static chat UI; calls the agent via the Foundry projects SDK |
| Platform (IaC) | [`infra/modules/containerapp.bicep`](../infra/modules/containerapp.bicep) | Container Apps environment, ACR, Log Analytics, user-assigned managed identity, role assignments |
| Deploy | [`scripts/deploy-webapp.ps1`](../scripts/deploy-webapp.ps1) | `az acr build` + `az containerapp create/update`, plus optional OBO wiring |

The image carries no customer data and no secrets — every value (endpoint, agent ID,
identity, OBO flag) is supplied as an environment variable at deploy time.

---

## Front-end options at a glance

The agent runtime ([03d](./03d-foundry-agent-setup.md)) is independent of how users reach
it. Three front ends are documented:

| Front end | Where users chat | Identity passthrough | Doc |
|---|---|---|---|
| **Copilot Studio combined channel** | Teams + M365 Copilot | per-user (Entra ID Integrated) | [03c](./03c-copilot-studio-setup.md) (different runtime) |
| **Custom engine agent** | Teams + M365 Copilot | per-user (SSO to agent) | [03d D6](./03d-foundry-agent-setup.md#phase-d6--publish-to-microsoft-365-copilot--teams-preview) |
| **Standalone web app** *(this doc)* | a branded web URL you own | **per-user via OBO** | **09** |

Choose the standalone web app for a self-hosted, brandable chat experience outside
Teams/M365 — for example an internal portal — with the agent runtime and tools unchanged.

---

## Identity: MI mode vs OBO mode

The app calls the agent in one of two ways, selected by the `ENABLE_OBO` environment
variable (set by the deploy script):

| | **MI mode** *(default)* | **OBO mode** *(opt-in: `-EnableObo`)* |
|---|---|---|
| The app calls the agent as | the Container App's **managed identity** | **the signed-in user** (`OnBehalfOfCredential`) |
| Azure AI Search tool | works (runs as its connection identity) | works |
| **Microsoft Fabric data agent tool** | **fails** — no user identity to pass through (service-principal / managed-identity auth is not supported by the Fabric tool) | **works** — the user's identity reaches Agent Service, so the Fabric tool (configured for identity passthrough) runs as that user and **row-/object-level security, Purview, and DLP are enforced per user** |
| Extra setup | none | Entra app registration + federated identity credential + Container Apps authentication |

Because this pattern's agent connects a **Fabric data agent**
([03d Phase D3](./03d-foundry-agent-setup.md#phase-d3--add-the-microsoft-fabric-data-agent-tool-structured-data)),
deploy in **OBO mode**. OBO is necessary but not sufficient on its own: it carries the
user token to Agent Service, while the **Fabric tool/connection must also be configured
for identity passthrough** in the portal ([03e](./03e-fabric-data-agent.md)). Most other
agent tools (MCP, OpenAPI, Logic Apps) run as the agent's own connection identity, so
always confirm per-user behavior with the two-user test in [Validate](#validate). The full
identity model is in [08-rbac-and-identity-passthrough.md](./08-rbac-and-identity-passthrough.md).

> If the agent uses **only** the Azure AI Search tool (no Fabric data agent), MI mode is
> sufficient and simpler — omit `-EnableObo`.

---

## Deploy

### W0 — Prerequisites

| Requirement | Detail |
|---|---|
| **A published Foundry agent** | The agent from [03d](./03d-foundry-agent-setup.md), with the Azure AI Search tool (and, in scope here, the Microsoft Fabric data agent tool). Note its **project endpoint** and **agent ID**. |
| **Azure platform deployed** | The base Bicep deployment ([Part B](./00-reproduce-this-demo.md#part-b--deploy-the-azure-platform-layer)), with `deployWebApp = true` (W1 below). |
| **Tooling** | **Azure CLI** and **PowerShell 7+**. No local Docker, `azd`, .NET, or Node toolchain is needed — the image builds in ACR. |
| **Entra admin consent** (OBO) | OBO provisioning creates a backend app registration whose delegated permission requires **admin consent**. Confirm an admin can grant it. |
| **Per-user Fabric access** (OBO) | Every end user needs **Read** on the Fabric data agent + its sources (Lakehouse Read; semantic model **Build**) — see [03e](./03e-fabric-data-agent.md) and [08 § Layer 3b](./08-rbac-and-identity-passthrough.md#layer-3b--foundry-agent-03d). |

### W1 — Provision the platform (Bicep)

Set `deployWebApp` to `true` in `infra/main.parameters.local.json`, then run the standard
deploy:

```pwsh
pwsh ./infra/deploy.ps1 -ParameterFile infra/main.parameters.local.json
```

This adds a Container Apps environment, an Azure Container Registry, a Log Analytics
workspace, and a user-assigned managed identity (granted AcrPull plus the Foundry
data-plane roles) to the resource group, and records their names in `demo-ids.local.json`.
The web-app platform is independent of the AI Search post-deploy step, so you may pass
`-SkipPostDeploy` if you only want to (re)provision the platform.

### W2 — Build and deploy the app

```pwsh
pwsh ./scripts/deploy-webapp.ps1 `
  -FoundryProjectEndpoint "https://<resource>.services.ai.azure.com/api/projects/<project>" `
  -AgentId "<agent-id>"
```

That is **MI mode** (default). For user-identity passthrough (required by the Fabric tool),
add `-EnableObo`:

```pwsh
pwsh ./scripts/deploy-webapp.ps1 -FoundryProjectEndpoint $endpoint -AgentId $agentId -EnableObo
```

The script reads the platform names from `demo-ids.local.json`, builds the image with
`az acr build`, creates/updates the Container App with the managed identity and external
ingress, sets the runtime environment variables, and — with `-EnableObo` — creates the
Entra app registration + federated identity credential (secretless OBO) and turns on
Container Apps authentication. It prints the app URL. Use `-WhatIf` to preview the az
commands without making changes.

### W3 — Finish OBO (only with `-EnableObo`)

The script wires the secretless exchange, but two grants need a directory admin and depend
on the current (preview) Foundry/Fabric specifics, so the script prints them rather than
guessing:

1. Add a **delegated permission** on the app registration for the Foundry data plane
   (Azure AI / Cognitive Services `user_impersonation`) and grant **admin consent**.
2. Grant each end user a **Foundry data-plane role** (e.g. Azure AI User) and **Read** on
   the Fabric data agent + sources ([03e](./03e-fabric-data-agent.md), [08](./08-rbac-and-identity-passthrough.md)).

---

## Validate

1. Open the printed app URL. In OBO mode, sign in as a normal user (not the deployer).
2. **Document question** (Azure AI Search tool): ask for a clause or wording from the
   indexed corpus; confirm a grounded answer.
3. **Structured question** (Fabric data agent tool): ask a count/aggregate (e.g. "how many
   executive-level offers are there?"); confirm the answer is correct.
4. **Per-user restriction** (OBO): sign in as **two users with different Fabric scope**
   (e.g. region-restricted via RLS) and ask the same "list all …" question — each must see
   only their permitted rows. This proves OBO passthrough end to end.
5. **Document trimming** (if configured): confirm in-group vs out-of-group results differ
   ([05 § G](./05-testing.md)).

A liveness probe is available at `/healthz` (unauthenticated) and reports whether the agent
endpoint and OBO mode are configured.

---

## RBAC & identity

The platform module and deploy script assign these. The full identity map and the
per-restriction enforcement model are in
[08-rbac-and-identity-passthrough.md](./08-rbac-and-identity-passthrough.md).

| Identity | Role / grant | Why |
|---|---|---|
| App **user-assigned managed identity** | **AcrPull** on the registry; **Foundry User**¹ + **Cognitive Services OpenAI Contributor**¹ on the Foundry resource | Pull the image; invoke the agent / project |
| **Backend app registration** (OBO only) | delegated permission + **admin consent**; **federated identity credential** trusting the app MI | Exchange the user token for an Agent Service token, secretlessly |
| **End user** (OBO) | a Foundry data-plane role to **call the agent** (e.g. **Foundry User**¹) **and** **Read** on the Fabric data agent + sources | The user must be allowed to invoke the agent; Fabric then enforces RLS/OLS/Purview for that user |
| Deployer | Subscription **Contributor** + **User Access Administrator** (role assignments), **plus** an Entra role that can create the app registration and grant **admin consent** (e.g. **Application Administrator**) for OBO | Run the Bicep + the deploy script |

> ¹ **Foundry RBAC** (per [Microsoft Learn](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry)). Use **Foundry User** for agent/project data-plane access — do **not** use *Azure AI Developer*, which is scoped to Azure ML workspaces and Foundry hubs, not Foundry projects/agents. *Foundry User / Owner / Project Manager* were formerly *Azure AI User / Owner / Project Manager* (role IDs unchanged). Re-verify at deploy time. See also [08 § Layer 3b](./08-rbac-and-identity-passthrough.md#layer-3b--foundry-agent-03d).

---

## Caveats

- **OBO is opt-in and adds dependencies** the Teams/M365 channel does not: a backend app
  registration, a federated identity credential, Container Apps authentication, and Entra
  **admin consent**.
- **SDK version + migration (act before 2026-08-26).** The app pins `azure-ai-projects`
  **v1.x** and uses the threads/messages/runs (Assistants-era) agents surface with a
  configurable token scope (`AGENT_TOKEN_SCOPE`, default `https://ai.azure.com/.default`).
  That surface is documented to **sunset 2026-08-26** with the classic Assistants API —
  migrate to the **`azure-ai-projects` v2.x Responses API** (`openai.responses.create` /
  conversations) before then. See [navigate from classic](https://learn.microsoft.com/azure/foundry/how-to/navigate-from-classic)
  and the [agent migration guide](https://learn.microsoft.com/azure/foundry/agents/how-to/migrate); re-verify the client surface + token scope at deploy time.
- **Preview surfaces.** The Foundry Fabric data agent tool is in preview; re-verify against
  current Microsoft Learn (see [03d](./03d-foundry-agent-setup.md) and [03e](./03e-fabric-data-agent.md)).
- **Conditional Access / device-compliance** policies can interfere with the OBO token
  exchange. Prefer a compliant environment for deploy and use.
- **Azure AI Search document-level trimming is still separate.** The AI Search tool runs as
  its connection identity, not the user — so the `group_ids` caller-filter from
  [08 § 5a](./08-rbac-and-identity-passthrough.md#5a-document-data-ai-search--no-passthrough-you-inject-the-filter)
  remains a deployment-specific step even in OBO mode.

---

## Validation checklist

- [ ] Foundry agent published with the AI Search (and, in scope, Fabric) tools (W0)
- [ ] Platform provisioned with `deployWebApp = true` (W1)
- [ ] App built + deployed; app URL reachable (W2)
- [ ] **OBO**: app registration + federated credential created, **admin consent** granted,
      per-user Foundry/Fabric grants in place (W2 + W3)
- [ ] Document + structured questions answer correctly (Validate)
- [ ] Two-user RLS check passes in OBO mode (Validate)

---

## References

- App: [webapp/app/](../webapp/app/) · Platform: [infra/modules/containerapp.bicep](../infra/modules/containerapp.bicep) · Deploy: [scripts/deploy-webapp.ps1](../scripts/deploy-webapp.ps1)
- Agent build: [03d-foundry-agent-setup.md](./03d-foundry-agent-setup.md) · Fabric data agent: [03e-fabric-data-agent.md](./03e-fabric-data-agent.md)
- Identity & RBAC: [08-rbac-and-identity-passthrough.md](./08-rbac-and-identity-passthrough.md)
- [Microsoft Foundry Agent Service overview](https://learn.microsoft.com/azure/foundry/agents/overview) · [Agent identity (OBO)](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity)
- [Azure Container Apps authentication](https://learn.microsoft.com/azure/container-apps/authentication) · [On-Behalf-Of flow](https://learn.microsoft.com/entra/identity-platform/v2-oauth2-on-behalf-of-flow)

---

*Last updated: 2026-06-19*

# 09 — Standalone web app front end (Microsoft Foundry agent webapp, OBO mode)

This document adds a **third front-end option** for the Foundry agent built in [03d](./03d-foundry-agent-setup.md): a **standalone web chat application** on Azure Container Apps, instead of (or alongside) the Microsoft 365 Copilot / Teams custom engine agent channel ([03d Phase D6](./03d-foundry-agent-setup.md#phase-d6--publish-to-microsoft-365-copilot--teams-preview)).

It uses the Microsoft sample **[microsoft-foundry/foundry-agent-webapp](https://github.com/microsoft-foundry/foundry-agent-webapp)** as the starter, deployed in its **On-Behalf-Of (OBO)** configuration — which is **required** for the agent's **Microsoft Fabric data agent tool**: OBO carries the signed-in user's identity through to Agent Service, so the Fabric tool can run queries as that user and enforce per-user data restrictions. (Most *other* agent tools run as the agent's own connection identity, not the caller — see the caveat in [§ RBAC & identity](#rbac--identity); verify the exact passthrough behavior against current Foundry/Fabric docs at deploy time.)

> **This repo does not fork or vendor the web app.** The upstream sample is a full .NET + React + `azd` application that evolves on its own cadence. Vendoring it here would create a maintenance and licensing burden and would drift from upstream. Instead, this folder ships a **thin configuration overlay** ([`webapp/`](../webapp/)) — an environment template, a deploy helper, and this runbook — that points the upstream starter at the agent built in 03d. Treat the upstream README as the source of truth for the app itself and **re-verify these steps against it at deploy time.**

---

## Front-end options at a glance

The agent runtime ([03d](./03d-foundry-agent-setup.md)) is independent of how users reach it. Three front ends are documented:

| Front end | Where users chat | Identity passthrough | Doc |
|---|---|---|---|
| **Copilot Studio combined channel** | Teams + M365 Copilot | per-user (Entra ID Integrated) | [03c](./03c-copilot-studio-setup.md) (different runtime) |
| **Custom engine agent** | Teams + M365 Copilot | per-user (SSO → agent) | [03d D6](./03d-foundry-agent-setup.md#phase-d6--publish-to-microsoft-365-copilot--teams-preview) |
| **Standalone web app** *(this doc)* | a branded web URL you own | **per-user via OBO** | **09** |

Choose the standalone web app when you want a self-hosted, brandable chat experience outside Teams/M365 — for example an internal portal — with the agent runtime and tools unchanged.

---

## Why OBO mode (not the default)

The web app supports two ways of calling Agent Service, selected at deploy time:

| | **MI mode** *(default)* | **OBO mode** *(this doc — opt-in)* |
|---|---|---|
| The app calls the agent as | the Container App's **managed identity** | **the signed-in user** (`OnBehalfOfCredential`) |
| Azure AI Search tool | works (uses its own connection identity) | works |
| **Microsoft Fabric data agent tool** | **fails** — no user identity to pass through (service-principal / managed-identity auth is not supported by the Fabric tool) | **works** — the user's identity reaches Agent Service, so the Fabric tool (configured for identity passthrough) runs as that user and **row-/object-level security, Purview, and DLP are enforced per user** |

Because this pattern's Foundry agent connects a **Fabric data agent** ([03d Phase D3](./03d-foundry-agent-setup.md#phase-d3--add-the-microsoft-fabric-data-agent-tool-structured-data)), the web app **must** be deployed in **OBO mode**. OBO is necessary but not sufficient on its own: it carries the user token to Agent Service, while the **Fabric tool/connection must also be configured for identity passthrough** in the portal ([03e](./03e-fabric-data-agent.md)). Most other agent tools (MCP, OpenAPI, Logic Apps) instead run as the agent's own connection identity, so always confirm per-user behavior with the two-user test in [W5](#validate-w5). The identity model — and why structured-data restrictions are enforced for you while document restrictions still need a filter — is detailed in [08-rbac-and-identity-passthrough.md](./08-rbac-and-identity-passthrough.md). The upstream documents OBO under **[Advanced: On-Behalf-Of (OBO) — opt-in](https://github.com/microsoft-foundry/foundry-agent-webapp#advanced-on-behalf-of-obo--opt-in)**.

> If the agent uses **only** the Azure AI Search tool (no Fabric data agent), MI mode is sufficient and simpler. This runbook assumes the Fabric tool is in scope and therefore uses OBO.

---

## Prerequisites (W0)

| Requirement | Detail |
|---|---|
| **A published Foundry agent** | The v2 agent from [03d](./03d-foundry-agent-setup.md), with the Azure AI Search tool (and, in scope here, the Microsoft Fabric data agent tool) added. Note its **agent ID/version**, **project endpoint**, and **resource ID**. |
| **Azure subscription** | Contributor on the target subscription/resource group (the deploy provisions Container Apps, ACR, a user-assigned managed identity, and — in OBO mode — an Entra app registration). |
| **Tooling** | **Azure Developer CLI (`azd`)**, **Azure CLI**, **PowerShell 7+**, **.NET SDK** and **Node.js** per the [upstream prerequisites](https://github.com/microsoft-foundry/foundry-agent-webapp#prerequisites). |
| **Entra admin consent** | OBO provisioning creates a backend API app registration and requires **admin consent** for its delegated permissions. Confirm an admin can grant it. |
| **Per-user Fabric access** | Every end user needs **Read** on the Fabric data agent + its sources (Lakehouse Read; Power BI semantic model **Build**) — see [03e](./03e-fabric-data-agent.md) and [08 § Layer 3b](./08-rbac-and-identity-passthrough.md#layer-3b--foundry-agent-03d). Without it, the Fabric tool call fails for that user. |

---

## Deploy (W1–W4)

The thin overlay in [`webapp/`](../webapp/) holds an environment template and a deploy helper. You can use the helper or run `azd` directly.

### W1 — Collect the agent identifiers

From the Foundry portal (or your 03d notes), gather:

- `AZURE_EXISTING_AGENT_ID` — e.g. `hr-knowledge-agent:2` (agent name + version)
- `AZURE_EXISTING_AIPROJECT_ENDPOINT` — e.g. `https://<resource>.services.ai.azure.com/api/projects/<project>`
- `AZURE_EXISTING_RESOURCE_ID` — `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<resource>`

Copy [`webapp/.env.example`](../webapp/.env.example) to `webapp/.env` and fill these in. Keep `webapp/.env` out of source control (the overlay [`.gitignore`](../webapp/.gitignore) already excludes it).

### W2 — Initialize the starter (outside this repo)

Scaffold the upstream app in a **separate directory outside this repository** so it is never committed here — this repo carries only the thin overlay, not the application:

```pwsh
# Run from the PARENT of this repo so the app is NOT created inside it.
mkdir foundry-agent-webapp; cd foundry-agent-webapp
azd init -t microsoft-foundry/foundry-agent-webapp
```

(Alternatively use the GitHub **Use this template** button or `git clone` per the upstream README — again, outside this repo.) You run the steps below from this app directory, pointing at the overlay's `webapp/.env`.

### W3 — Enable OBO + point at the agent

From the app directory created in W2, set the existing-agent values and **turn on OBO** before provisioning:

```pwsh
azd env set AZURE_EXISTING_AGENT_ID        "<agent-name>:<version>"
azd env set AZURE_EXISTING_AIPROJECT_ENDPOINT "https://<resource>.services.ai.azure.com/api/projects/<project>"
azd env set AZURE_EXISTING_RESOURCE_ID     "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<resource>"

# Enable On-Behalf-Of (creates the backend app registration + federated identity
# credential + admin consent). REQUIRED for the Microsoft Fabric data agent tool.
azd env set ENABLE_OBO true
```

> **Confirm the OBO flag at deploy time.** The upstream exposes OBO as a Bicep parameter (`enableObo`) fed by the `azd` environment variable **`ENABLE_OBO`** — the name used by [`webapp/.env.example`](../webapp/.env.example) and the helper. Upstream names can change, so verify in the **[Advanced: OBO — opt-in](https://github.com/microsoft-foundry/foundry-agent-webapp#advanced-on-behalf-of-obo--opt-in)** section before running `azd up`. [`webapp/deploy-webapp.ps1`](../webapp/deploy-webapp.ps1) reads these from `webapp/.env` and applies them for you.

### W4 — Provision and deploy

```pwsh
azd up
```

`azd up` discovers the Foundry resource, provisions the infrastructure, and — with OBO enabled — creates the Entra app registration, the **federated identity credential (FIC)** on the user-assigned managed identity (secretless OBO), and triggers **admin consent**, then builds and deploys the container. It finishes by opening the deployed app URL.

---

## Validate (W5)

1. Sign in to the deployed web app as a normal user (not the deployer).
2. **Document question** (Azure AI Search tool): ask for a clause or wording from the indexed corpus; confirm a grounded answer with citation.
3. **Structured question** (Fabric data agent tool): ask a count/aggregate (e.g. "how many executive-level offers are there?"); confirm the tool call appears in the UI and the answer is correct.
4. **Per-user restriction:** sign in as **two users with different Fabric scope** (e.g. region-restricted via RLS) and ask the same "list all …" question — each must see only their permitted rows. This proves OBO passthrough end-to-end.
5. **Document trimming (if configured):** confirm in-group vs out-of-group results differ ([05 § G](./05-testing.md)).

---

## RBAC & identity

The web app does not change the agent's RBAC — it changes **which identity calls the agent**. The full identity map and the per-restriction enforcement model live in **[08-rbac-and-identity-passthrough.md](./08-rbac-and-identity-passthrough.md)**. Summary for this front end:

| Identity | Role / grant | Why |
|---|---|---|
| Container App **user-assigned managed identity** | ACR pull; **Cognitive Services OpenAI Contributor** + **Azure AI Developer**¹ on the Foundry resource; acts as the **FIC assertion** for OBO | Pull image; call the model/agent plane; secretless OBO token exchange |
| **Backend API app registration** (OBO only) | delegated permission + **admin consent** | Lets the app exchange the user token for an Agent Service token on the user's behalf |
| **End user (OBO)** | a Foundry data-plane role to **call the agent** (e.g. **Azure AI User**¹ on the Foundry resource) **and** **Read** on the Fabric data agent + sources (Lakehouse Read / semantic model **Build**) | The user must be allowed to invoke the agent; Fabric then enforces RLS/OLS/Purview for that user |
| Deployer | Subscription **Contributor**, **plus** an Entra directory role that can create the app registration and grant **admin consent** (e.g. **Application Administrator**) when OBO is enabled | Run `azd up`; provision the OBO app registration + federated identity credential |

> ¹ **Verify exact role names at deploy time.** The upstream `azd` flow assigns these roles automatically, and Foundry's data-plane roles were renamed (e.g. *Azure AI Developer* / *Azure AI User* now appear under **Foundry** naming). Confirm the current names in the upstream README and [08 § Layer 3b](./08-rbac-and-identity-passthrough.md#layer-3b--foundry-agent-03d).

> **Two caveats to validate:**
> 1. The upstream notes that most agent tools (MCP, OpenAPI, Logic Apps) use the **agent's own connection identity** from the portal. The **Fabric data agent tool is the passthrough exception** — it relies on the user identity reaching Agent Service, which only happens in OBO mode. Test it explicitly with two users.
> 2. **Azure AI Search document-level trimming is still separate.** The AI Search tool runs as its connection identity, not the user — so the `group_ids` caller-filter from [08 § 5a](./08-rbac-and-identity-passthrough.md#5a-document-data-ai-search--no-passthrough-you-inject-the-filter) remains a deployment-specific step even in OBO mode.

---

## Caveats

- **OBO is opt-in and adds dependencies** the Teams/M365 channel does not: a backend app registration, a federated identity credential, and Entra **admin consent**.
- **Conditional Access / device-compliance** policies can interfere with OBO token exchange at token-use time (the upstream flags this for Codespaces). Prefer a compliant environment for deploy and use.
- **Upstream drift.** Pin or re-verify the upstream commit/README at deploy time; env var names, role grants, and the OBO flow can change.
- **Preview surfaces.** The Foundry Fabric data agent tool is in preview; re-verify against current Microsoft Learn (see [03d](./03d-foundry-agent-setup.md) and [03e](./03e-fabric-data-agent.md)).

---

## Validation checklist

- [ ] Foundry agent published with the AI Search (and, in scope, Fabric) tools (W0)
- [ ] `webapp/.env` filled with the agent endpoint / ID / resource ID (W1)
- [ ] Starter initialized via `azd init -t microsoft-foundry/foundry-agent-webapp` (W2)
- [ ] **OBO enabled** (`azd env set ENABLE_OBO true`, name verified against upstream) before `azd up` (W3)
- [ ] `azd up` completed; backend app registration + FIC + admin consent provisioned (W4)
- [ ] Document + structured questions answer correctly in the deployed app (W5)
- [ ] Two-user RLS check passes (per-user Fabric restriction enforced via OBO) (W5)

---

## References

- Upstream sample: [microsoft-foundry/foundry-agent-webapp](https://github.com/microsoft-foundry/foundry-agent-webapp) · [Advanced: OBO — opt-in](https://github.com/microsoft-foundry/foundry-agent-webapp#advanced-on-behalf-of-obo--opt-in)
- Agent build: [03d-foundry-agent-setup.md](./03d-foundry-agent-setup.md) · Fabric data agent: [03e-fabric-data-agent.md](./03e-fabric-data-agent.md)
- Identity & RBAC: [08-rbac-and-identity-passthrough.md](./08-rbac-and-identity-passthrough.md)
- Overlay: [webapp/README.md](../webapp/README.md)
- [Microsoft Foundry Agent Service overview](https://learn.microsoft.com/azure/foundry/agents/overview) · [Agent identity (OBO)](https://learn.microsoft.com/azure/foundry/agents/concepts/agent-identity)

---

*Last updated: 2026-06-19*

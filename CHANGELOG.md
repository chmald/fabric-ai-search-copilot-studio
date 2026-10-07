# Changelog — RAG Knowledge-Base Pattern

Change history for this pattern. Entries are listed newest-first.

---

## 2026-10-07

### v1.7.0 — Current demo standard: docs layout, `azd up`, configuration reference, reusability guards, Learn currency pass

Brings the pattern up to the current demo-pattern standard (hard rules #4, #14, #16–#19) and re-verifies the fast-moving claims against Microsoft Learn. Also records the 2026-10-02 visual retrofit (official V24 icons, local badges, callouts, 16 draw.io diagrams + PNGs, `scripts/lint_doc_visuals.py`), which shipped without its own entry.

**Docs renumbered to the standard layout** (`git mv`, history preserved; every link, anchor, diagram label and code comment updated):

| Old | New |
|---|---|
| `docs/04-deployment-automated.md` | `docs/03-deployment.md` (now opens with *Fast path — azd up* + Phase 0 tenant auth) |
| `docs/03-deployment-manual.md` | `docs/03b-manual-deployment.md` |
| `docs/05-testing.md` | `docs/04-testing.md` |
| `docs/06-troubleshooting.md` | `docs/05-troubleshooting.md` (new *A — azd triage* section) |
| `docs/03b-fabric-setup.md` | `docs/06-fabric-setup.md` |
| `docs/03c-copilot-studio-setup.md` | `docs/07-copilot-studio-setup.md` |
| `docs/03d-foundry-agent-setup.md` | `docs/08-foundry-agent-setup.md` |
| `docs/03e-fabric-data-agent.md` | `docs/09-fabric-data-agent.md` |
| `docs/07-copilot-studio-vs-foundry.md` | `docs/10-copilot-studio-vs-foundry.md` |
| `docs/08-rbac-and-identity-passthrough.md` | `docs/11-rbac-and-identity-passthrough.md` |
| `docs/09-foundry-agent-webapp.md` | `docs/12-foundry-agent-webapp.md` |
| — | `docs/13-configuration-reference.md` (new) |
| `docs/assets/03d-foundry-agent-setup-tool-routing.*` | `docs/assets/foundry-agent-tool-routing.*` |
| `scripts/tests/test_post_deploy_search.py` | `tests/test_post_deploy_search.py` (+ `pytest.ini`; pipeline runs `pytest tests/`) |

Historical entries below keep their original wording; their links now point at the new file names.

**One-command deployment (hard-rule #17).** `azure.yaml` + subscription-scoped `infra/azd.bicep` (wraps the shared `main.bicep`, passes every parameter) + `infra/azd.parameters.json` (quoted `${VAR=default}` substitutions) + hooks: `preprovision` validates names (storage-name length), **stops unless `az account show` matches `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID`**, restores a soft-deleted Foundry account / recovers a soft-deleted Key Vault (or purges with `PURGE_SOFT_DELETED=true`) and keeps `RESTORE_FOUNDRY_FROM_SOFT_DELETE` in step; `postprovision` writes `demo-ids.local.json` and runs `post_deploy_search.py` (`CONFIGURE_SEARCH`). The ids writer, tenant guard, soft-delete guard and post-deploy call live in `infra/hooks/common.ps1`, which `infra/deploy.ps1` now dot-sources (new optional `-TenantId` / `-SubscriptionId` guard). `main.bicep` gained `resourceGroupName`, `embeddingModelSku` and `chatModelSku` (defaults keep existing behaviour). `.gitignore` excludes `.azure/`. New diagram `azd-deployment-flow`.

**Configuration reference (hard-rule #18).** `docs/13-configuration-reference.md` lists every azd variable, output, Bicep / script parameter, ids-file key and runtime env var, with a `configuration-flow` diagram and recipes; `tests/test_configuration.py` fails when any of them is undocumented or when `azd.bicep` stops passing a `main.bicep` parameter.

**Structural reusability (hard-rule #14).** `demo-ids.template.json` gains `_template` / `_note` and a **`corpus` block** — the only domain-specific surface (index/skillset names, content analyzer, embedding width, indexer schedule, Search API version, accepted file types, chunk size/overlap, agent + knowledge-source name/description). `post_deploy_search.py` reads it (`corpus.<key>` → flat key → code default); embedding width is no longer inferred from the model name alone. `docs/01` gains *Adapting this pattern to another domain*. New `tests/test_reusability_guards.py` (caught and fixed two `hr-…` example IDs in `webapp/app/main.py` and `scripts/deploy-webapp.ps1`) and `tests/test_retarget_domain.py`. The Fabric notebook tokenizer uses `tiktoken.get_encoding("o200k_base")` instead of a model name.

**Microsoft Learn currency pass (2026-10-07) — corrections:**
- **Semantic ranker tier** — was "requires Standard (S1); not available on Basic". Semantic ranker runs on Basic and above (free plan + per-1,000-request standard plan) ([semantic ranker](https://learn.microsoft.com/azure/search/semantic-search-overview)); Free is excluded only because it has no managed identity ([managed identities](https://learn.microsoft.com/azure/search/search-how-to-managed-identities)). S1 stays the default for capacity; `searchSku` / `SEARCH_SKU` now allows `basic`. Storage figures updated to 15 GB (Basic) / 160 GB (S1) per partition for current services ([limits](https://learn.microsoft.com/azure/search/search-limits-quotas-capacity)).
- **Foundry → Teams / Microsoft 365 Copilot publishing** — was "preview (custom engine agent)". [Publish agents to Microsoft Copilot and Teams](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot) is documented without a preview label (Azure Bot Service, publisher needs Azure Bot Service Contributor + Foundry User); docs/08 Phase D6 now leads with portal publish, the Agents Toolkit custom engine agent is the optional route, and the comparison in docs/10 / README / diagrams is updated. The **Microsoft Fabric tool remains preview** ([Fabric tool](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/fabric)).
- **Classic agents retirement** — v1.6.1 said the classic runtime "sunsets 2026-08-26". Learn now separates the dates: the **Assistants API sunset on 2026-08-26**; **Foundry Agent Service (classic)** (threads/runs, `azure-ai-projects` 1.x) **retires 2027-03-31** ([navigate from classic](https://learn.microsoft.com/azure/foundry/how-to/navigate-from-classic), [migrate](https://learn.microsoft.com/azure/foundry/agents/how-to/migrate)). The web app still uses the 1.x surface — flagged as an open migration item in docs/12 (it can't call agents built the GA way until migrated to `azure-ai-projects` ≥ 2.3).
- **Chat model suggestions** — `gpt-4o` / `gpt-4o-mini` are deprecated/legacy (2024-05-13 retires 2026-12-09; others 2027-04-14) per the [retirement schedule](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirement-schedule); examples now use `gpt-5.5` (GA to 2027-10-26) / `gpt-5.4-mini`, and the opt-in chat deployment defaults to `GlobalStandard`. `text-embedding-3-large` (GA to 2028-02-09) is unchanged.
- **Document-level access control** — security filters are GA; POSIX ACL/RBAC, Purview labels and SharePoint ACLs are preview on the latest preview REST API (`2026-08-01-preview`), not a fixed "2026-05-01" ([overview](https://learn.microsoft.com/azure/search/search-document-level-access-overview)).
- **Search API versions** — data-plane `2024-07-01` stays the (supported GA) default and is now configurable via `corpus.searchApiVersion`; latest GA is `2026-04-01` with no breaking changes for the features used ([API versions](https://learn.microsoft.com/azure/search/search-api-versions)). `Microsoft.Search/searchServices` moved from `2024-03-01-preview` to stable `2025-05-01` (`hostingMode: 'Default'`); `infra/main.json` recompiled.
- Confirmed unchanged: Document Intelligence `2024-11-30` + `prebuilt-read`; Copilot Studio Azure AI Search knowledge source (GA, Entra ID Integrated auth, vector index required); Fabric Data Agent GA; AI Search tool GA in Foundry Agent Service.

**Visuals.** New `azd-deployment-flow` and `configuration-flow` diagrams; 9 existing diagrams updated for the corrections above; every footer at v1.7.0; all PNGs re-exported and reviewed; `version.svg` badge regenerated. `lint_doc_visuals.py --strict`: 0 errors / 0 warnings; `validate-drawio.py --richness`: 18/18 OK.
---

## 2026-06-19

### v1.6.1 — Microsoft Learn currency + accuracy pass
A verification pass against current Microsoft Learn plus an internal-alignment audit of the v1.6 web app.

- **RBAC fix (functional):** the web-app managed identity now uses **Foundry User** (`53ca6127-db72-4b80-b1b0-d745d6d5456d`) for agent/project access instead of **Azure AI Developer**. Per the [Foundry RBAC docs](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry), *Azure AI Developer* is scoped to Azure ML workspaces / Foundry hubs — **not** Foundry projects or hosted agents (`infra/modules/containerapp.bicep`, `docs/09`).
- **Date fix:** corrected the classic Foundry/Assistants runtime retirement to **sunsets 2026-08-26** (was 2027-03-31) in `docs/03d` and the v1.4 note, per [navigate from classic](https://learn.microsoft.com/azure/foundry/how-to/navigate-from-classic).
- **SDK migration note:** flagged that the web app pins `azure-ai-projects` **v1.x** (threads/runs Assistants-era surface), which sunsets 2026-08-26 — added migration guidance to the v2.x Responses API in `docs/09`, `webapp/app/requirements.txt`, and `webapp/app/main.py`.
- **Doc alignment:** added the web-app front end + its identities to `docs/01` (Layer-3 table) and `docs/08` (identity inventory); added the optional `containerapp.bicep` row to `docs/04`; removed a stale `azd` block from the root `.gitignore`; corrected a `containerapp.bicep` header comment (`az acr build` + `az containerapp create/update`, not `az containerapp up`).
- **Link hygiene:** fixed pre-existing broken doc anchors — `mssal`→`msal` (11 links), an indexer link (`§4.3`→`§4.4`), a `06`→`03c` knowledge-source link, an `03e`→`samples` anchor, and a `03b` self-link.

### v1.6 — Web app front end moved in-repo (single-source deploy)
Replaced the external-sample overlay (v1.5) with a **self-contained, in-repo chat front end** so the whole pattern deploys from one source with one toolchain (Bicep + PowerShell + Azure CLI). No `azd`, no .NET/React, nothing scaffolded outside the repo.

- **`webapp/app/`** (new) — a minimal **FastAPI** app (`main.py` + `static/index.html` + `Dockerfile`) that relays messages to the 03d agent. Supports **MI mode** (default; `DefaultAzureCredential`) and secretless **OBO mode** (`OnBehalfOfCredential` via a federated managed identity) for the Fabric data agent tool's per-user passthrough.
- **`infra/modules/containerapp.bicep`** (new) — optional hosting platform (Container Apps environment, ACR, Log Analytics, user-assigned managed identity + role assignments), gated by the new **`deployWebApp`** parameter on `infra/main.bicep` (default false). The image builds from source in ACR — no local Docker.
- **`scripts/deploy-webapp.ps1`** (new) — single web-app deploy: `az acr build` + `az containerapp create/update`, with `-EnableObo` for the app registration + federated credential + Container Apps authentication. `-WhatIf` supported.
- **`docs/09`** rewritten for the in-repo flow; **`webapp/README.md`** / **`.env.example`** / **`.gitignore`** repurposed for the app; the old `webapp/deploy-webapp.ps1` overlay and the external-sample references were removed.
- Cross-links updated in the README file index, [03d Phase D6](./docs/08-foundry-agent-setup.md), and [00-reproduce](./docs/00-reproduce-this-demo.md).

Honesty notes carried in the docs: OBO needs admin consent + per-user Foundry/Fabric grants (the script prints the manual steps rather than guessing preview specifics); verify the `azure-ai-projects` surface, token scope, API version, and Foundry role names at deploy time; Conditional Access can interfere with OBO; AI Search document-level trimming (`group_ids`) remains separate even in OBO mode.

### v1.5 — Standalone web app front-end option (Foundry agent webapp, OBO)
Added a **third front-end option** for the Foundry agent ([03d](./docs/08-foundry-agent-setup.md)): a self-hosted web chat app on Azure Container Apps, alongside the M365/Teams custom engine agent. It uses the Microsoft sample [foundry-agent-webapp](https://github.com/microsoft-foundry/foundry-agent-webapp) deployed in **On-Behalf-Of (OBO)** mode — **required** so the signed-in user's identity reaches Agent Service and the **Microsoft Fabric data agent tool** can enforce per-user RLS/OLS/Purview (the app's default MI mode cannot pass user identity, and the Fabric tool does not support service-principal/managed-identity auth). The agent runtime and tools are unchanged — only the client differs.

The upstream app is **not forked or vendored**. This repo ships a **thin configuration overlay** plus a runbook:

- **`docs/12-foundry-agent-webapp.md`** (new) — front-end options comparison, the MI-vs-OBO rationale, prerequisites, deploy steps (`azd init` → enable OBO → `azd up`), a two-user RLS validation, RBAC/identity (cross-referenced to [08](./docs/11-rbac-and-identity-passthrough.md)), and caveats.
- **`webapp/`** (new) — `README.md`, `.env.example` (agent identifiers + the `ENABLE_OBO` flag, placeholders only), `deploy-webapp.ps1` (thin `azd` wrapper), `.gitignore` (excludes the populated `.env` and `azd` state; the upstream app is scaffolded outside this repo, not vendored).
- Cross-linked from the README file index, [03d Phase D6](./docs/08-foundry-agent-setup.md), and [00-reproduce](./docs/00-reproduce-this-demo.md).

Honesty notes carried in the docs: OBO is opt-in and adds an app registration + federated identity credential + admin consent; the `azd` OBO flag is **`ENABLE_OBO`** (maps to the Bicep `enableObo` parameter) — verify against the upstream README at deploy time; OBO carries the user identity to Agent Service while the **Fabric tool/connection must also be configured for identity passthrough** (most other agent tools run as the agent's own connection identity); role-name assignments are auto-granted by `azd` and Foundry data-plane role names have changed — verify at deploy time; Conditional Access can interfere with OBO token exchange; AI Search document-level trimming (`group_ids`) remains a separate step even in OBO mode.

## 2026-06-10

### v1.4 — Terminology refresh: Azure AI Foundry → Microsoft Foundry
Aligned the pattern's product naming with current Microsoft Learn terminology. **Azure AI Foundry is now branded *Microsoft Foundry*** (per the official [Evolution of Foundry](https://learn.microsoft.com/azure/foundry/what-is-foundry) mapping; the former `what-is-azure-ai-foundry` page now redirects under `/azure/foundry/`). The newer `03d` / `03e` / `08` docs already used the current name — this brings the README and the rest of the docs into line. **No architectural or technical change:** the resource is still `Microsoft.CognitiveServices/accounts` `kind=AIServices`, and the OpenAI-compatible (`*.openai.azure.com`) and Cognitive Services (`*.cognitiveservices.azure.com`) endpoints are unchanged.

Verified current against Microsoft Learn (no change needed): Microsoft Foundry Agent Service is **GA** (the classic Assistants-API runtime sunsets **2026-08-26**); in the agent, the **Azure AI Search tool is GA** and the **Microsoft Fabric (Data Agent) tool is preview**; M365/Teams **custom engine agent** publishing remains **preview**; the **Fabric data agent** itself is **GA**; AI Search **semantic ranker** + **integrated vectorization**, Copilot Studio **knowledge source** + **generative answers**, and Document Intelligence **prebuilt-read** are all current terms.

Changes:
- **Global rename** `Azure AI Foundry` → `Microsoft Foundry` (64 occurrences) across `README.md`, `CHANGELOG.md`, `docs/00`–`07`, `samples/README.md`, `infra/main.bicep`, and `infra/modules/aifoundry.bicep`. A one-time "(formerly Azure AI Foundry)" note was added on first mention in `README.md` and `docs/01-architecture.md`.
- **`docs/08-foundry-agent-setup.md`** — standardized "Microsoft Foundry Agents Service" → **"Microsoft Foundry Agent Service"** (canonical singular).
- **`README.md` / `docs/01-architecture.md` / `docs/02-prerequisites.md` / `docs/03b-manual-deployment.md` / `infra/modules/aifoundry.bicep`** — dropped the now-legacy **"Hub"** from the Foundry-runtime aside (`Agent Service / Hub / Projects` → `Agent Service and projects`); hub-based projects are the classic model and Foundry projects are the current one.

## 2026-06-09

### v1.3 — Microsoft Foundry Agent Service as the alternative Layer-3 path (licensing-driven)
Added a second, interchangeable implementation of **Layer 3 (the conversational layer)**: the agent can now be built on **Microsoft Foundry Agent Service** instead of Copilot Studio, connecting **Azure AI Search** *and* a **Fabric Data Agent** as native Foundry tools and publishing to Teams + M365 Copilot as a **custom engine agent (preview)**. This addresses a licensing constraint: when a Copilot Studio agent connects Azure AI Search + a Fabric Data Agent, those are pulled in as **premium / message-capacity-billed connectors** on top of M365 Copilot. Moving the runtime to Foundry shifts that cost to **Azure consumption** while end users keep consuming on their existing M365 Copilot license. Layers 1–2 (Fabric ingest, Blob, AI Search index, Foundry model gateway) are **unchanged** — only the conversational layer swaps, so the two paths are interchangeable without re-indexing.

**The architectural decisions are unchanged** — Copilot Studio remains the **default** for low-code knowledge-base Q&A; the Foundry agent path is the documented **alternative** for licensing-blocked, structured-data-RLS, or richer-orchestration scenarios. Publishing a Foundry agent into M365/Teams is **preview** — flagged throughout as "verify at build time."

Changes:
- **`docs/08-foundry-agent-setup.md`** (new) — full alternative runbook (Phases D0–D6): licensing delta, required chat-model deployment, AI Search tool (project MI → **Search Index Data Reader**), Fabric Data Agent tool (**on-behalf-of** caller identity → Fabric RLS), agent authoring + security trimming, playground test, M365/Teams custom-engine-agent publishing (preview), a **high-level RBAC summary**, and a validation checklist.
- **`docs/10-copilot-studio-vs-foundry.md`** (new) — decision guide: shared-substrate framing, side-by-side table, **licensing deep-dive** (the licensing driver + honest cost-shift caveats), pros/cons for each runtime, decision matrix, and a Layer-3-only migration note.
- **`README.md`** — file-index rows for 03d + 07; the Foundry note's **Agent runtime** row now cites the licensing driver and links 03d/07; deployment-paths + quick-start prereqs updated to present the 03c-or-03d agent choice.
- **`docs/01-architecture.md`** — new **Layer 3 alternative** subsection (component table) + a variant Mermaid diagram, updated "intentionally left out" Foundry row, and versioning row 1.3.
- **`docs/02-prerequisites.md`** — § 6 **Alternative — Microsoft Foundry agent path** prereq table; § 10 **Foundry agent path — additional assignments** RBAC table with the two-line RBAC-delta summary.
- **`docs/00-reproduce-this-demo.md`** — Part D restructured to present the **D-CS / D-FA** Layer-3 choice (03d phase table D0–D6), single-page checklist + Part A references updated.

## 2026-06-08

### v1.2 — Document/chunk-level access control (security trimming)
Added a chunk-level access-control story to the pattern, addressing a per-chunk security requirement in the vector index. **Per-chunk security = document-level access control** because each chunk is one AI Search index document. Of the four Azure AI Search approaches ([overview](https://learn.microsoft.com/azure/search/search-document-level-access-overview)), the pattern adopts **GA security filters** as the production baseline (chunks are *derived* JSON, so source ACLs don't survive OCR/chunking — a push-model `group_ids` field is the reliable mechanism); Purview sensitivity labels (preview) are noted as the strategic OneLake/Fabric-aligned follow-on.

Changes:
- **`scripts/post_deploy_search.py`** — added `group_ids` field (`Collection(Edm.String)`, filterable + retrievable) to the index schema.
- **`docs/06-fabric-setup.md`** — chunk JSON payload now carries `group_ids`, populated from the source document's resolved Entra group object IDs (`resolve_source_group_ids(file_id)`; `[]` = visible to all).
- **`docs/01-architecture.md`** — added schema field, a "Document-level (chunk-level) access control" subsection under Trust boundaries (4 approaches, GA-vs-preview, push-model trim, derived-chunk caveat, Copilot Studio per-user filter nuance), cross-ref from the "intentionally left out" table, and Versioning row 1.2.
- **`docs/07-copilot-studio-setup.md`** — added a security-trimming note under § C0.3 tying **Entra ID Integrated** (calling-user identity) to `group_ids` trimming, with the honest Copilot Studio filter-injection nuance.
- **`docs/04-testing.md`** — new **test category G (document-level security)** with runnable AI Search `$filter` queries (in-group sees / out-of-group trimmed) — the demonstrable "working example" at the index/API layer.

**Correction:** prior wording in `01-architecture.md` ("Copilot Studio → AI Search: API key / admin/query key") was stale. The locked design **disables local auth** on AI Search and uses **Microsoft Entra ID** for the Copilot Studio data connection (Entra ID Integrated or Service principal), as already documented in 03c § C0.3. Both the Identity and Secrets bullets were corrected.



### Deployer Key Vault Secrets Officer grant added to Bicep
`infra/modules/rbac.bicep` now grants `deployerPrincipalId` the **Key Vault Secrets Officer** role on the Key Vault (gated by the same `!empty(deployerPrincipalId)` check as the Search role grants). Without this, the operator hits `403 Forbidden` on `az keyvault secret set` when storing the DI-caller SP secret in [docs/06-fabric-setup.md § F2.2 step 3](./docs/06-fabric-setup.md). The manual path in [docs/03b-manual-deployment.md §§ 1.2 and 1.7](./docs/03b-manual-deployment.md) now includes the explicit `az role assignment create` command for the same grant.

### Soft-delete restore for Foundry resource (opt-in pattern)
Added an opt-in `restoreFoundryFromSoftDelete` Bicep parameter (default `false`) and a matching `-RestoreFoundry` switch on `infra/deploy.ps1`. When the param is `true`, `infra/modules/aifoundry.bicep` adds `properties.restore: true` to the Foundry account via `union()`; otherwise the property is omitted. Rationale: an always-on `restore: true` was tried first but rejected by the Cognitive Services ARM provider on fresh creates with `CanNotRestoreANonExistingResource: Could not locate a resource to restore`. The opt-in pattern is the correct stable shape — fresh deploys are unaffected, and operators recover from `FlagMustBeSetForRestore` by re-running `pwsh ./infra/deploy.ps1 -RestoreFoundry`. Preserving the MI matters because the DI-caller SP's `Cognitive Services User` role assignment on the Foundry resource is granted manually (per [docs/06-fabric-setup.md § F2.2 step 2](./docs/06-fabric-setup.md)) and would be orphaned by any purge-and-recreate cycle. See [docs/05-troubleshooting.md § 0.5](./docs/05-troubleshooting.md#05-bicep-deploy-fails-flagmustbesetforrestore-soft-deleted-foundry--cognitive-services-account).

### Chat completion deployment made opt-in
Changed `chatModelName` default from `gpt-4o` to `''` in `infra/main.bicep` and `main.parameters.json`. The `chatDeployment` resource in `modules/aifoundry.bicep` is now wrapped in `if (!empty(chatModelName))`. Rationale: an audit found that no code path in the locked design consumes the chat completion model — `scripts/post_deploy_search.py` only references the embedding deployment, the Fabric OCR notebook only calls Document Intelligence, AI Search vectorizer/skillset only embed, and Copilot Studio's generative answers run on its own host model (the M365 Copilot model). The `gpt-4o` deployment was provisioned just-in-case and consumed 10K TPM of subscription quota for no benefit. Opt in by setting `chatModelName` to `gpt-4o` (or `gpt-4o-mini`) when a deployment explicitly needs a chat endpoint (custom app code, Foundry agent runtime, Copilot Studio bring-your-own-model). The `deploymentSummary` Bicep output now also emits a `chatDeployed: bool` flag so tooling can branch on it.

## 2026-05-25

### AI Search Bicep auth fix
Removed the `authOptions: { aadOrApiKey: ... }` block from `modules/search.bicep` — the Azure Search API treats `authOptions` and `disableLocalAuth: true` as mutually exclusive (`BadRequest: AuthOptions must be null if DisableLocalAuth is true`). Bearer challenges still work by default when local auth is disabled. See [docs/05-troubleshooting.md § 0.4](./docs/05-troubleshooting.md#04-bicep-deploy-fails-authoptions-must-be-null-if-disablelocalauth-is-true).

### Document Intelligence consolidated into the Microsoft Foundry resource
Removed the standalone `Microsoft.CognitiveServices/accounts` of `kind=FormRecognizer` (and its `modules/docintelligence.bicep` module + its dedicated managed identity + duplicate Storage Blob Data Reader role assignment). DI is now served by the Foundry account (`kind=AIServices` is a multi-service Cognitive Services account). Net result: 4 Azure resources instead of 5, single MI for both OpenAI and DI storage access, single RBAC surface. See [docs/01-architecture.md § 8](./docs/01-architecture.md#8-document-intelligence-prebuilt-read-served-by-the-foundry-resource) for the design rationale.

## 2026-05-22

### Artifact restructure
`docs/` folder layout, Bicep IaC + 5 modules, dual deployment path (manual + automated), ADO pipeline.

## 2026-05-21

### Locked architecture decisions
Copilot Studio orchestration for knowledge-base Q&A, Foundry as model gateway, integrated vectorizer, hybrid + semantic ranker, OneLake + Blob storage, Fabric Data Pipelines.

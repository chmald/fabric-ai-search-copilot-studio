# 02 — Prerequisites

Everything required before you can start building. Work through this list in order; the deployment guide assumes all of these are in place.

> **Plan ahead.** Several items (Copilot Studio licensing, Foundry access approval, Fabric capacity allocation, AI Search tier selection) involve administrative approvals that can take hours to days. Start the slowest-moving ones first.

> **Shell convention.** Every shell snippet in this doc set is **PowerShell** (`pwsh` 7+), tagged ```` ```pwsh ````. The deployment wrapper is [`infra/deploy.ps1`](../infra/deploy.ps1). Variables use `$VAR = "value"`; line continuations use backtick `` ` ``; HTTP examples use `curl.exe` (not `Invoke-WebRequest` aliases) or `Invoke-RestMethod`. JSON responses are handled with native `ConvertFrom-Json` / `Select-Object` — **no `jq` dependency**. See [README § Shell convention](../README.md#shell-convention) for the full convention map.

---

## 0 — Local developer tooling

Install these on the workstation you'll use to drive the build before working through the Azure / Fabric / Copilot Studio prerequisites below.

| Tool | Minimum version | Used for |
|---|---|---|
| [PowerShell 7+ (`pwsh`)](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) | 7.4+ | Running every shell snippet in `docs/*.md` and `infra/deploy.ps1` (cross-platform: Windows, macOS, Linux) |
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | 2.60+ | All `az ...` commands; `az login` for interactive auth |
| [Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (CLI extension) | latest | `az bicep build` + `az deployment sub create`. Install once: `az bicep install` |
| [Python](https://www.python.org/downloads/) | 3.11+ | `scripts/post_deploy_search.py` and `scripts/tests/*` |
| [Git](https://git-scm.com/downloads) | any recent | Clone / commit |

Verify your environment in one shot:

```pwsh
$PSVersionTable.PSVersion          # PowerShell version (>= 7.4)
az --version                       # Azure CLI version (>= 2.60); Bicep CLI shown in same output
python --version                   # Python version (>= 3.11)
az bicep install                   # idempotent; ensures Bicep CLI is present
```

> **Why pwsh and not bash.** The deployment wrapper [`infra/deploy.ps1`](../infra/deploy.ps1) is a PowerShell script (parameters, switches, error-handling all use PowerShell idioms). Standardizing the docs on the same shell removes a copy-paste failure mode and means the same examples work identically on Windows, macOS, and Linux. The `az` CLI itself is shell-agnostic — if you prefer bash for one-off commands, the `az ...` invocations are unchanged; you only need to convert `$VAR = "value"` to `VAR=value` and backtick line continuations to `\`.

---

## 1 — Azure subscription

### Required

- An **Azure subscription** with **Contributor** + **User Access Administrator** rights on the resource group that will host the pattern
- Budget approval for the recurring monthly cost (rough estimate at the bottom of this page)

### Why both Contributor and User Access Administrator

Several integration points require **role assignments**, not just resource creation:

- Assigning managed identity → Storage Blob Data Reader on Blob
- Assigning AI Search managed identity → Cognitive Services OpenAI User on the Foundry resource
- Assigning Fabric workspace identity → Blob Data Contributor on Blob

Contributor-only is **not enough**; you will hit "Authorization failed" errors when wiring up identities.

---

## 2 — Resource providers

In the target subscription, register these resource providers (one-time, takes a few minutes):

- `Microsoft.CognitiveServices` (Microsoft Foundry — same provider also covers Document Intelligence, served from the same Foundry account)
- `Microsoft.Search`
- `Microsoft.Storage`
- `Microsoft.KeyVault`
- `Microsoft.Fabric` (if not auto-registered by the tenant)

```pwsh
# CLI check
az provider list --query "[?registrationState=='Registered'].namespace" -o tsv
```

If any are missing:

```pwsh
az provider register --namespace Microsoft.CognitiveServices --wait
```

---

## 3 — Microsoft Foundry (model gateway)

### Required

- **Microsoft Foundry resource** (Azure CLI / ARM kind: `AIServices`) in the target subscription + region. This is the **strategic model-gateway resource** that supersedes the legacy standalone Azure OpenAI resource for new deployments. A single Foundry resource hosts all OpenAI models you deploy and also exposes the broader Foundry model catalog (Cohere, Llama, Phi, Mistral, etc.) under one endpoint.
- **Two OpenAI model deployments** inside the Foundry resource:
  - **Embedding** — recommended: `text-embedding-3-large` (3072 dim). Acceptable fallback: `text-embedding-3-small` (1536 dim) for cost-sensitive demos.
  - **Chat completion** — **optional**. The locked design does NOT consume a chat completion model (Copilot Studio uses its own host model for generative answers). Only deploy one when a deployment explicitly needs a chat endpoint: custom app code, Foundry agent runtime, or Copilot Studio bring-your-own-model. When you opt in, the recommended model is `gpt-4o` (cost-down: `gpt-4o-mini`). Set `chatModelName` in [infra/main.parameters.local.json](../infra/main.parameters.json) to opt in.

> **Why Foundry resource over the legacy AOAI resource?** The Microsoft Foundry resource is Microsoft's strategic direction for all new AI model deployments. It exposes the same OpenAI-compatible endpoint (`https://<resource>.openai.azure.com/`) so all existing tooling — including the AI Search integrated `azureOpenAI` vectorizer — works unchanged, while giving you a single resource for all model families (current + future) and a single capacity / billing / content-safety plane.

> **Important:** this pattern uses Foundry's **model-gateway** capability only. It does **not** use Foundry's agent runtime (Agent Service and projects); Copilot Studio's native AI Search knowledge source fills that role. Foundry agent runtime is the right addition when a deployment needs multi-agent routing, custom tool calling, or query triage — that's a deployment-specific decision, not part of this pattern's default stack.

### Region availability check

Not every model is available in every region. Confirm before provisioning:

- Microsoft Learn: "Microsoft Foundry models and region availability" / "Azure OpenAI models and region availability" (search current Microsoft Learn — region matrix updates frequently)
- Or query the resource directly:

```pwsh
az cognitiveservices account list-models `
  --name <your-foundry-resource> `
  --resource-group <your-rg> `
  --query "[].{model:name, version:version, locations:capabilities.locations}"
```

### Approval and quota

- Foundry OpenAI access is gated. If this is a new subscription, request access via the **Limited Access** form first (the same form historically used for standalone Azure OpenAI access).
- Each deployment requires **TPM (tokens-per-minute) quota** assignment. For demo: 10K TPM per deployment is sufficient. For production: size based on expected concurrent users × tokens per turn.

### Region recommendation

Choose a region with **both** model deployments available and with availability for AI Search Standard tier. Common pairings: `East US`, `East US 2`, `West Europe`, `Sweden Central`, `Australia East`.

---

## 4 — Azure AI Search

### Required

- **AI Search service** at **Standard (S1) or higher** tier
- Semantic ranker enabled (one toggle per service)
- Managed identity (system-assigned) enabled

### Why Standard minimum

| Tier | Semantic ranker | Storage | Recommendation |
|---|---|---|---|
| Free | ❌ | 50 MB | Demo only — cannot run this pattern |
| Basic | ❌ | 2 GB | Cannot run this pattern |
| **Standard S1** | ✅ | 25 GB / partition | **Minimum for this pattern** |
| Standard S2 / S3 | ✅ | Higher | Production scale |
| L1 / L2 | ✅ | Multi-TB | Multi-million doc corpora |

### Semantic ranker pricing model

Standard tier includes a **free semantic-ranker quota** (currently 1,000 queries / month at time of writing — confirm current quota in Microsoft Learn). Beyond that, semantic queries are metered (~$1 / 1,000 queries). For demos and pilots, free quota is usually sufficient.

### Capacity guidance

- **Demo / pilot:** 1 replica, 1 partition (default)
- **Production:** start with 1 replica (read availability), scale partitions based on storage; add replicas as QPS grows

---

## 5 — Microsoft Fabric

### Required

- **Fabric tenant** enabled (most M365 tenants have this by default — confirm with tenant admin)
- **Fabric capacity** (F-SKU) assigned to the workspace where you'll build
- **Workspace** in that capacity where you have **Admin** or **Member** role
- The workspace has a **Lakehouse** (or you have rights to create one)

### Capacity sizing

| SKU | Use |
|---|---|
| **F2** | Demo only — very limited; pipelines may queue |
| **F4 / F8** | Pilot, ≤ 10K docs |
| **F16+** | Production-grade for this pattern |

If you have shared Fabric capacity, confirm there is headroom; ingestion pipelines can spike capacity usage.

### Tenant settings to confirm with the Fabric admin

- **Use OneLake shortcuts** — enabled
- **Use the Fabric Data Pipelines (preview / GA depending on tenant)** — enabled
- **Service principal can use Fabric APIs** — enabled if you plan to automate

---

## 6 — Copilot Studio

### Required

- **Copilot Studio license** for the building user (Maker access)
- An **environment** in Power Platform / Copilot Studio that you can publish to
- Connectivity to the target Azure tenant (Copilot Studio and AI Search can be in different tenants but it's simpler if they're the same)

### License options

| License | Capability |
|---|---|
| Copilot Studio user license | Full agent build + publish |
| Copilot Studio trial | OK for demo build; not for prod |
| Bundled M365 Copilot | Some agent-building rights vary by plan; check current Microsoft Learn for the agent-builder rights matrix |

### Channel publishing rights

- **Teams channel** publishing requires Power Platform admin approval (one-time per environment)
- **M365 Copilot agent** publishing requires the M365 admin to enable third-party agents in M365 Copilot

Initiate these admin asks **before** you start building so they're cleared by the time you're ready to publish.

### Alternative — Microsoft Foundry agent path (03d)

If you are building the agent on **Microsoft Foundry Agent Service** instead of Copilot Studio (see [03d](./03d-foundry-agent-setup.md) and the decision guide [07](./07-copilot-studio-vs-foundry.md)), the Layer-3 prerequisites change:

| Requirement | Copilot Studio path (03c) | Foundry agent path (03d) |
|---|---|---|
| **Builder license/RBAC** | Copilot Studio Maker | **Azure AI Developer** (or Project Manager) on a Foundry project |
| **Chat-model deployment** | Not required (host model answers) | **Required** — deploy `gpt-4o` (or `gpt-4o-mini`) on the `aif-rag-<env>` resource; confirm TPM quota |
| **Fabric Data Agent** | Optional connector (premium) | A **published Fabric Data Agent** in the workspace (for structured-data Q&A); Fabric admin enables Copilot/Azure OpenAI + Data Agents |
| **Runtime billing** | Copilot Studio **message capacity** / per-user license | **Azure consumption** (tokens + tool calls + search QU + Fabric capacity) |
| **Channel** | Native combined Teams + M365 Copilot (GA) | **Custom engine agent** via M365 Agents SDK/Toolkit (**preview**) |
| **End-user license** | Microsoft 365 Copilot | Microsoft 365 Copilot (**unchanged**) |
| **Teams admin approval** | One-time per environment | One-time per app (same gate) |

The end-user license is identical on both paths; the difference is **where the runtime is billed** (Power Platform message packs vs. Azure consumption) and **who builds it** (maker vs. Foundry builder). This is the licensing difference for deployments constrained by premium-connector / message-capacity cost.

---

## 7 — Azure Document Intelligence

### Required

- **No separate resource.** Document Intelligence is provided by the Foundry resource from § 6 — a `kind=AIServices` account is a multi-service Cognitive Services account that exposes both Azure OpenAI and Document Intelligence (and the rest of the Cognitive Services catalogue) from the same resource. See [01-architecture.md § 8](./01-architecture.md#8-document-intelligence-prebuilt-read-served-by-the-foundry-resource) for the design rationale.
- The DI SDK / REST endpoint is the Foundry resource's `https://<name>.cognitiveservices.azure.com/` host (the OpenAI vectorizer uses the `<name>.openai.azure.com/` host on the same resource).
- Foundry's `S0` SKU covers DI usage — no separate page quota.
- Only the `prebuilt-read` model is used — no custom training or Document Intelligence Studio work required.

---

## 8 — Azure Storage (Blob)

### Required

- **Storage account** (Standard tier, GRS or LRS depending on durability needs)
- Two **containers**:
  - `raw/` — original files, used for citation linkback
  - `chunks/` — chunk JSON files, indexed by AI Search

### Storage class recommendation

- **Hot** tier for `chunks/` (read frequently by indexer)
- **Cool** tier acceptable for `raw/` if file size is large and access is rare (the citation linkback typically returns a pre-signed URL, not bulk reads)

---

## 9 — Azure Key Vault

### Required

- **Key Vault** in the target subscription + region
- **Access policy / RBAC mode** decided (RBAC strongly preferred for new deployments)
- Granted **Key Vault Secrets Officer** (or equivalent) to the building user for the duration of the build

> **This pattern stores zero AI-service secrets in Key Vault.** Foundry (which serves both OpenAI **and** Document Intelligence), AI Search, and Storage all have local auth / shared-key access disabled — every cross-service call goes through Entra ID via managed identity. Key Vault is kept in the deployment as the standard place to put any secret that gets added later (e.g. credentials for a Snowflake / SharePoint Online / SQL Server connector you wire into the Fabric pipeline). If you delete the Key Vault module from `infra/main.bicep`, nothing in the default pattern breaks.

---

## 10 — RBAC role assignments (cheat sheet)

These are the role assignments required by the pattern's Entra-only auth posture. List them out in advance so you can request them in batch if Owner approvals are required.

> The full cross-layer identity map (ingest → platform → agent) plus the identity-passthrough / per-user-restriction model is consolidated in [08-rbac-and-identity-passthrough.md](./08-rbac-and-identity-passthrough.md).

### Machine-to-machine (assigned in Bicep `modules/rbac.bicep` or in [03-deployment-manual.md § 1.7](./03-deployment-manual.md#17-rbac-wiring))

| Principal | Role | Scope | Why |
|---|---|---|---|
| AI Search service managed identity | **Cognitive Services OpenAI User** | Foundry resource | Integrated vectorizer authenticates to the embedding deployment with a bearer token — **critical**. Must be the OpenAI-specific role, **not** plain `Cognitive Services User` (silent-failure trap — see [06-troubleshooting.md § 4.1](./06-troubleshooting.md)). |
| AI Search service managed identity | **Storage Blob Data Reader** | Storage account (or `chunks/` container) | Indexer pulls chunk JSON — **critical** |
| Foundry resource managed identity | **Storage Blob Data Reader** | Storage account (or `raw/` container) | Document Intelligence (served from the Foundry account) fetches `urlSource` files via its own MI — required because shared-key access on Storage is disabled |
| Fabric workspace identity | **Storage Blob Data Contributor** | Storage account | Copy / chunk-upload activities write to `raw/` + `chunks/`. Assigned manually in [03b-fabric-setup.md § F2.1](./03b-fabric-setup.md#f21-grant-the-workspace-identity-the-required-roles) once the workspace identity exists |
| DI-caller service principal (`sp-rag-di-caller`) | **Cognitive Services User** | Foundry resource | Fabric notebook calls Document Intelligence via MSAL with this SP's secret — see [03b-fabric-setup.md § F2.2](./03b-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook) |

### Builder / deployer (assigned to the user or service principal running deploys)

| Principal | Role | Scope | Why |
|---|---|---|---|
| Building user / deploy SP | **Search Service Contributor** | AI Search service | Create / update index, datasource, indexer via REST bearer token (admin keys are disabled) |
| Building user / deploy SP | **Search Index Data Contributor** | AI Search service | Run sample queries against `/docs/search` during build + test |
| Building user | **Storage Blob Data Contributor** | Storage account | Upload / inspect blobs through Azure CLI / portal during build |
| Building user | **Cognitive Services Contributor** | Foundry resource | Deploy models, change settings, see Identity blade. Covers both the OpenAI deployments **and** the Document Intelligence usage (same resource). |
| Building user | **Key Vault Secrets Officer** | Key Vault | Manage any secrets you add later for downstream connector credentials |

> When using the automated path, set the `deployerPrincipalId` parameter in `infra/main.parameters.local.json` to your object ID; Bicep then assigns the two Search roles for you. The remaining builder roles still need to be granted manually (typically once per environment, not per deploy).

### Foundry agent path (03d) — additional assignments

Only needed if you build Layer 3 on **Microsoft Foundry Agent Service** instead of Copilot Studio. These are **incremental** to the machine-to-machine grants above (which stay in place — the index, indexer, and vectorizer are unchanged).

| Principal | Role | Scope | Why | New? |
|---|---|---|---|---|
| **Foundry *project* managed identity** | **Search Index Data Reader** | AI Search service | The agent's **AI Search tool** runs read-only queries against `idx-rag-documents` | New |
| **Foundry project MI / caller** | **Cognitive Services OpenAI User** | Foundry resource | Agent generates answers on the chat deployment | New |
| **Caller user identity (on-behalf-of)** | **Viewer** (+ read/build on the model/Lakehouse) | Fabric workspace | Fabric Data Agent answers within the **user's** RLS/OLS scope (per-user HR-data trimming) | New |
| Building user / deploy SP | **Azure AI Developer** (or **Project Manager**) | Foundry project | Create the agent, tools, connections, deployments | New |
| Custom-engine-agent **bot** (Entra app) | **Azure AI User** (or the toolkit-configured project connection) | Foundry project / agent | Teams bot forwards user turns to the agent endpoint | New |

> **Two-line summary of the RBAC delta:** grant the **Foundry project managed identity `Search Index Data Reader`** on the search service (so the agent can query the index), and flow the **caller's user identity (on-behalf-of)** into the Fabric Data Agent (so HR row-level security is enforced per user). Everything else is already in place from the base deploy or is a standard Foundry builder/bot grant. Full detail: [03d § RBAC summary](./03d-foundry-agent-setup.md#rbac-summary--high-level).

---

## 11 — Regional alignment

This pattern has a strong **co-location** requirement: AI Search, the Foundry resource (which hosts your OpenAI embedding model and the Document Intelligence OCR endpoint), Blob Storage, Key Vault, and your Fabric capacity should all live in the **same Azure region** wherever possible. The dominant constraint is **OpenAI model availability** — `text-embedding-3-large` (and `gpt-4o` if you opt in to a chat deployment) is not in every region, and these are the only services in the stack whose regional rollout lags meaningfully behind general Azure availability.

Copilot Studio's environment region is independent and can differ from the Azure region; choose it based on your data-residency policy.

**Cross-region egress** is the most common silent cost driver and the most common latency surprise in this pattern. Pay attention to it during region selection.

### Tier-1 recommended regions (full stack, current OpenAI rollout, multi-AZ resilience)

These are the regions where every component of the pattern stack is currently available at production-grade SKUs **and** new OpenAI model deployments tend to land first or near-first. Default here unless data-residency forces you elsewhere.

| Region | Geography | Use for |
|---|---|---|
| **East US 2** | Americas | Default US choice; strong OpenAI capacity; consistent first-mover for new model deployments |
| **Sweden Central** | EMEA | Default EU choice; strong OpenAI capacity; preferred over older EU regions for OpenAI workloads |
| **Australia East** | APAC | Default APAC choice (non-Japan); full stack with reliable model availability |
| **Japan East** | APAC | Japan data-residency; full stack with reliable model availability |

### Tier-2 acceptable regions (full stack, but model rollout may lag)

Choose from Tier 2 when data-residency, latency to your users, or existing Azure footprint outweighs the model-rollout-lag concern. Always verify the specific model deployments are available **at deployment time** — see verification commands below.

| Region | Geography | Notes |
|---|---|---|
| East US | Americas | Older sibling of East US 2; still solid but East US 2 is preferred for new builds |
| West US 3 | Americas | Newer Azure region; broad service parity; lower model availability in some matrices |
| North Central US | Americas | US central residency |
| Canada Central / Canada East | Americas | Canada data-residency |
| West Europe (Amsterdam) | EMEA | Strong EU footprint; OpenAI availability lags Sweden Central for newest models |
| North Europe (Dublin) | EMEA | Ireland residency; chat models reliable, embedding model availability mixed |
| France Central | EMEA | France residency |
| UK South | EMEA | UK residency; OpenAI availability has improved but still verify per-model |
| Switzerland North | EMEA | Switzerland residency; verify embedding availability per quota (and gpt-4o if opting in to a chat deployment) |
| Korea Central | APAC | Korea residency |

### Tier-3 regions (workarounds required)

Other regions (UAE North, South Africa North, Brazil South, Central India, etc.) typically require either (a) cross-region OpenAI calls or (b) substituting an alternate model. Both options break the "all-in-region" simplicity of this pattern. **Default away from Tier 3** unless data-residency demands it; if it does, plan for cross-region egress cost and additional latency.

### Component availability matrix (as of pattern publication — VERIFY at deployment time)

> ✅ available · ⚠️ available but rollout often lags / quota-limited · ❌ not available at the time of this matrix's authoring

| Region | AI Search S1+ | Foundry resource | text-embedding-3-large | gpt-4o (opt-in) | Doc Intel prebuilt-read | Fabric F-SKU |
|---|---|---|---|---|---|---|
| East US 2 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| East US | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| West US 3 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| North Central US | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| South Central US | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| Canada Central | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Canada East | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Sweden Central | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| West Europe | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| North Europe | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| France Central | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| UK South | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| Switzerland North | ✅ | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| Germany West Central | ✅ | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| Australia East | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Japan East | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Japan West | ✅ | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| Korea Central | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| Southeast Asia | ✅ | ✅ | ⚠️ | ✅ | ✅ | ✅ |
| Central India | ✅ | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| UAE North | ✅ | ✅ | ⚠️ | ⚠️ | ✅ | ⚠️ |
| Brazil South | ✅ | ✅ | ⚠️ | ⚠️ | ✅ | ✅ |
| South Africa North | ✅ | ✅ | ❌ | ⚠️ | ⚠️ | ⚠️ |

**Universally available (any Azure region)** — not in matrix because they don't constrain region choice: Blob Storage, Key Vault.

### Why these regions are the recommendation

1. **Model availability is the only hard constraint.** AI Search, Blob, Key Vault, and Fabric are widely available; pick a region for them and they will work. OpenAI deployments (in the Foundry resource that also serves Document Intelligence) are the bottleneck.
2. **OpenAI model rollouts cluster.** When a new OpenAI model lands in Azure, it typically reaches East US 2, Sweden Central, Australia East, and Japan East within the first wave. These four regions are the "follow Azure OpenAI's roadmap" choices.
3. **Co-location preserves the no-egress story.** The integrated vectorizer (AI Search → Foundry) and the indexer (AI Search → Blob) both produce non-trivial inter-service traffic. In-region calls are sub-millisecond and free; cross-region calls add cost and meaningfully degrade indexing throughput.
4. **Semantic ranker latency is region-sensitive.** The semantic ranker adds 300–500 ms at p95 in a single region. Cross-region between AI Search and Foundry can push that to 1+ second.
5. **Data residency takes precedence.** If your residency policy points at a Tier-2 or Tier-3 region, choose that region — residency outweighs the model-rollout-lag concern. Plan to refresh model deployments quarterly to stay current.

### Verify at deployment time

The matrix above is a **publication-time snapshot**. Region × model availability moves monthly. Always confirm before provisioning:

```pwsh
# 1. List OpenAI models available in your target region
az cognitiveservices model list `
  --location <region> `
  --query "[?contains(model.name, 'text-embedding-3-large') || contains(model.name, 'gpt-4o')].{model:model.name, version:model.version}" `
  -o table

# 2. Check Azure AI Search SKU availability in your target region (Standard S1+ required for semantic ranker)
az search service list-skus --location <region> -o table

# 3. Check Fabric capacity availability (region list updates as Fabric expands)
# (No CLI as of pattern publication — verify in Fabric Admin Portal → Capacities → Region)
```

If any of the three checks fail for your preferred region, fall back to the next Tier-1 region within the same residency boundary.

---

## 12 — Naming convention (reference)

A consistent naming convention makes the build navigable and replicable. Suggested scaffold (adjust to your organization's standards):

```
Resource group:   rg-<workload>-<env>-<region>           e.g.  rg-rag-demo-eus
AI Search:        srch-<workload>-<env>-<region>         e.g.  srch-rag-demo-eus
AI Foundry:       aif-<workload>-<env>-<region>          e.g.  aif-rag-demo-eus
                  (multi-service — serves OpenAI models AND Document Intelligence;
                   no separate `di-*` resource is provisioned)
Storage:          st<workload><env><region>              e.g.  stragdemoeus  (lowercase, no hyphens)
Key Vault:        kv-<workload>-<env>-<region>           e.g.  kv-rag-demo-eus
Fabric workspace: ws-<workload>-<env>                    e.g.  ws-rag-demo
Lakehouse:        lh_<workload>_<env>                    e.g.  lh_rag_demo
Pipeline:         pl_ingest_<workload>                   e.g.  pl_ingest_docs
Index:            idx-<workload>-documents               e.g.  idx-rag-documents
Copilot agent:    agent-<workload>                       e.g.  agent-rag-kb
```

---

## 13 — Quotas to check before you start

| Service | Quota | Typical demo need | Where to check |
|---|---|---|---|
| Foundry | TPM per OpenAI deployment | 10K each (embedding + chat) | Azure portal → Foundry resource → Quotas (uses the AOAI quota plane for OpenAI models) |
| Foundry | Number of OpenAI deployments | 2 (embedding + chat) | Same |
| AI Search | Services per subscription | 1 | Azure portal → subscription → Usage + quotas → Search |
| AI Search | Semantic ranker queries / month | Free quota or paid | AI Search service → Semantic ranker blade |
| Document Intelligence (served by the Foundry resource) | Pages per month | Standard tier: ≥ 1M | Azure portal → Foundry resource → Quotas (the DI sub-namespace shares Foundry's Cognitive Services quota plane) |
| Storage | Account count + capacity | 1 account, ≤ 100 GB for demo | Subscription quotas |
| Fabric | Capacity headroom | Demo: F4–F8 | Fabric Admin Portal |

---

## 14 — Rough cost estimate

Indicative monthly costs for a **demo / pilot** scale (single region, ~10K docs corpus, low query volume). Actuals vary by region; pull current pricing for your scenario.

| Component | Demo cost / month (USD) | Notes |
|---|---|---|
| AI Search Standard S1 | ~$250 | One replica, one partition |
| Foundry — OpenAI embedding (text-embedding-3-large) | ~$10–$50 | One-time bulk embed + low ongoing |
| Foundry — OpenAI chat (gpt-4o) | $0 by default; ~$50–$200 if opted in | Optional. The locked design does not deploy a chat model. Scales with query volume when enabled. |
| Document Intelligence (prebuilt-read) | ~$15–$30 | $1.50 / 1K pages |
| Blob Storage (Hot, ~50 GB) | ~$2 | |
| Key Vault | ~$1 | |
| Fabric F4 capacity | ~$525 (24/7) or pause when idle | Major variable cost; pause aggressively for demos |
| Copilot Studio license | Per-user | Usually already in your M365 footprint |
| **Total (demo, capacity paused off-hours)** | **~$400–$600 / month** | |

**Production** scale (~100K–1M docs, sustained QPS) typically lands **$2K–$10K / month** range with the largest variable being Fabric capacity sizing.

---

## 15 — Pre-flight checklist

Confirm all of these before moving to your chosen deployment path — [03-deployment-manual.md](./03-deployment-manual.md) (portal / CLI walkthrough) or [04-deployment-automated.md](./04-deployment-automated.md) (Bicep + script):

- [ ] Azure subscription chosen, Contributor + User Access Administrator confirmed
- [ ] Target region(s) chosen with all 5 Azure services available
- [ ] Foundry resource access approved + quota assigned for embedding + chat OpenAI deployments
- [ ] AI Search Standard tier budget approved
- [ ] Fabric capacity allocated to a workspace
- [ ] Copilot Studio license assigned to the builder
- [ ] Channel publishing pre-approvals initiated (Teams + M365 Copilot)
- [ ] Naming convention agreed
- [ ] Document source identified + access path (SharePoint shortcut, file share, etc.) planned

Once all boxes are checked → proceed to [03-deployment-manual.md](./03-deployment-manual.md) for the portal walkthrough OR [04-deployment-automated.md](./04-deployment-automated.md) for the Bicep + script-driven path.

---

*Last updated: 2026-05-21*

# 00 — Reproduce this demo

> **Audience.** Someone who wants to clone this repo and stand up the full RAG knowledge-base demo against a fresh Azure subscription + Fabric tenant + Copilot Studio environment. Each Part below is a discrete checkpoint — finish A before starting B, etc. The deep-dive runbooks ([03-deployment-manual.md](03-deployment-manual.md), [03b-fabric-setup.md](03b-fabric-setup.md), [03c-copilot-studio-setup.md](03c-copilot-studio-setup.md), [04-deployment-automated.md](04-deployment-automated.md), [05-testing.md](05-testing.md), [06-troubleshooting.md](06-troubleshooting.md)) are linked from the specific steps that consume them rather than duplicated here.

> **Time budget.** First-time stand-up: roughly **4–6 hours** end-to-end for the manual path, **2–3 hours** for the Bicep-automated path (which still requires manual Fabric + Copilot Studio steps). Time is dominated by waits on quota / model deployment propagation and Copilot Studio publishing approvals. Subsequent reproductions in the same tenant: **under 1 hour** for the automated path.

---

## What you'll end up with

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Azure DevOps                                                            │
│   ├─ Repo: this codebase                                                │
│   ├─ Pipeline: .azuredevops/pipelines/deploy-rag-kb.yml                 │
│   │     (Validate Bicep → Deploy Bicep → Configure AI Search index)     │
│   └─ Variable groups: rag-kb-env-dev / -prod                            │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ az deployment sub create + REST
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Azure Subscription                                                      │
│   Resource group: rg-rag-dev-eastus2                                    │
│   ├─ Key Vault            kv-rag-dev-eastus2                            │
│   ├─ Storage account      stragdeveastus2 (containers: raw, chunks)     │
│   ├─ AI Foundry resource  aif-rag-dev-eastus2                           │
│   │     ├─ embedding deployment: text-embedding-3-large                 │
│   │     ├─ chat deployment:      (opt-in — not deployed by default)      │
│   │     └─ Document Intelligence: prebuilt-read (same account, kind=AIServices) │
│   └─ AI Search (Standard) srch-rag-dev-eastus2                          │
│         ├─ index:    idx-rag-documents (hybrid + semantic ranker)       │
│         ├─ data src: ds-chunks (managed-identity → Blob)                │
│         └─ indexer:  ixr-chunks (integrated AOAI vectorizer)            │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ Fabric Data Pipeline                     │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Microsoft Fabric                                                        │
│   Workspace: ws-rag-dev                                                 │
│   ├─ Lakehouse:        lh_rag_dev (OneLake source + control table)      │
│   └─ Data Pipeline:    pl_ingest_docs (OCR via notebook → chunk → Blob) │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ AI Search knowledge source               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Copilot Studio                                                          │
│   Agent: agent-rag-kb                                                   │
│   ├─ Knowledge: idx-rag-documents (Azure AI Search, semantic search ON) │
│   └─ Channels:  Teams and Microsoft 365 Copilot (single combined channel) │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites checklist (verify before starting Part A)

- [ ] **Azure subscription** with Contributor + User Access Administrator on the target RG (or subscription scope for greenfield)
- [ ] **Region chosen** from [02-prerequisites.md § 11](./02-prerequisites.md) Tier-1 list — default: **East US 2** for US, **Sweden Central** for EU, **Australia East** / **Japan East** for APAC
- [ ] **Azure OpenAI access approved** in the subscription with TPM quota for `text-embedding-3-large` (10K TPM minimum for demo). `gpt-4o` quota is only required if you opt in to a chat deployment for deployment-specific extensions (the locked design doesn't consume one).
- [ ] **Fabric capacity** allocated (F4+ for demo, F16+ for production) and a workspace where you have Admin or Member role
- [ ] **Copilot Studio license** for the building user — and channel-publishing pre-approvals **initiated** (Teams + M365 Copilot admin approvals take ~1-2 business days)
- [ ] **Local tools** (full table in [02-prerequisites.md § 0](./02-prerequisites.md#0--local-developer-tooling)): **PowerShell 7+ (`pwsh`)**, **Azure CLI 2.60+** with the `bicep` extension installed (`az bicep install`), **Python 3.11+**, `git`. All shell snippets in the docs are PowerShell — see [README § Shell convention](../README.md#shell-convention).
- [ ] **(For automated path only)** Ability to authenticate to Azure with an identity that has the role assignments above (e.g. `az login` with your user, or a service principal for ADO)

If any of these are missing, see [02-prerequisites.md](./02-prerequisites.md) for the full breakdown.

---

## Part A — Choose your deployment path

Two paths produce the same end-state:

| Path | When to use | Doc |
|---|---|---|
| **A1. Manual / portal + CLI** | Learning the architecture; one-off demo labs; first time you touch this pattern | [03-deployment-manual.md](./03-deployment-manual.md) |
| **A2. Automated / Bicep** | Repeated deployments; CI/CD; multiple environments (dev/prod); production stand-up | [04-deployment-automated.md](./04-deployment-automated.md) |

Both paths skip Fabric workspace creation and Layer-3 agent configuration in their respective deep-dives — each is **always manual** (no Bicep / IaC surface exists today) and each has its own dedicated document: Fabric in [03b-fabric-setup.md](./03b-fabric-setup.md), and the agent in [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md) (Copilot Studio) **or** [03d-foundry-agent-setup.md](./03d-foundry-agent-setup.md) (Microsoft Foundry). Both layers are identical regardless of which Azure path you chose in A1 / A2.

---

## Part B — Deploy the Azure platform layer

### B1. (Path A1) Manual portal walkthrough

Follow [03-deployment-manual.md](./03-deployment-manual.md) § Phase 1 (foundation), then jump to [03b-fabric-setup.md](./03b-fabric-setup.md) for Fabric (covered in Part C below), then return to [03-deployment-manual.md § Phase 4](./03-deployment-manual.md#phase-4--ai-search-index) for the AI Search index/datasource/indexer. This Path A1 leg provisions the Azure resources only: RG, Key Vault, Storage + 2 containers, Doc Intelligence, AI Foundry + 2 model deployments, AI Search Standard tier with semantic ranker, all RBAC role assignments, AI Search index + datasource + indexer with integrated vectorizer.

Validation: end of Phase 4 — `Indexer last run = success, items processed = chunk JSON count`.

### B2. (Path A2) Bicep + post-deploy script

Follow [04-deployment-automated.md](./04-deployment-automated.md). This runs `pwsh ./infra/deploy.ps1` (or the equivalent `az deployment sub create`), which provisions everything in B1 except the AI Search index/datasource/indexer. Then `python scripts/post_deploy_search.py` creates the search-side resources via REST using the deployment outputs.

Validation: `pwsh ./infra/deploy.ps1 -Verify` reports all resources Ready and the indexer succeeded.

---

## Part C — Stand up the Fabric workspace (manual — both paths)

Fabric is **always manual** (no Bicep / Terraform / IaC surface for workspaces, Lakehouses, shortcuts, or pipelines as of this pattern's publication). The full step-by-step is in its own document: **[03b-fabric-setup.md](./03b-fabric-setup.md)**.

What 03b covers end-to-end (Phases F0–F10):

| 03b Phase | What you build |
|---|---|
| F0 | Tenant + capacity prerequisites |
| F1 | Workspace creation + capacity assignment |
| F2 | Workspace identity + Blob Data Contributor grant |
| F3 | Lakehouse `lh_rag_<env>` |
| F4 | OneLake shortcut to the source system (SharePoint / ADLS / S3 / etc.) |
| F5 | Control `control_table_files` Delta table |
| F6 | Fabric connections to Key Vault and Blob Storage |
| F7 | Three pipeline notebooks (lookup, chunk+upload, control-table upsert) |
| F8 | Data Pipeline `pl_ingest_docs` — lookup notebook → Refresh SQL Endpoint → Lookup → ForEach (Copy + mark_pending + `nb_ocr_chunk_upload` + mark_succeeded). Document Intelligence is called from the OCR notebook via MSAL + a DI-caller service principal (secret in Key Vault, fetched by the workspace identity); no Web activity, no Until polling, and no child pipeline are needed. |
| F9 | End-to-end validation on sample docs |
| F10 | Pipeline schedule |

### Part C validation

- [ ] Workspace + Lakehouse + workspace identity created ([03b §§ F1–F3](./03b-fabric-setup.md))
- [ ] OneLake shortcut populated with sample documents ([03b § F4](./03b-fabric-setup.md#phase-f4--attach-the-source-via-onelake-shortcut))
- [ ] Pipeline succeeds end-to-end on sample docs ([03b § F9](./03b-fabric-setup.md#phase-f9--validate-end-to-end))
- [ ] Control table has rows with `ocr_status = succeeded` and `chunk_status = succeeded`
- [ ] Blob `chunks/` container has JSON files; AI Search indexer picks them up within ~5 min

---

## Part D — Build the agent (manual — both paths)

Layer 3 has **two interchangeable implementations** — build **one**. Neither is expressible in Bicep. Pick with [07-copilot-studio-vs-foundry.md](./07-copilot-studio-vs-foundry.md):

| Option | Runtime | Best for | Doc |
|---|---|---|---|
| **D-CS. Copilot Studio** | Power Platform | Lowest-code, fully GA, small audience or CS capacity already licensed | [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md) |
| **D-FA. Microsoft Foundry agent** | Foundry Agent Service | **Licensing constraint** (AI Search + Fabric Data Agent premium connectors), structured-data RLS, richer orchestration — accepts **preview** M365/Teams publishing | [03d-foundry-agent-setup.md](./03d-foundry-agent-setup.md) |

### Option D-CS — Copilot Studio

Copilot Studio agents are not expressible in Bicep (Power Platform, not Azure). The full step-by-step is in its own document: **[03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md)**.

What 03c covers end-to-end (Phases C0–C6):

| 03c Phase | What you build |
|---|---|
| C0 | Tenant + licensing prerequisites, channel-publishing approvals |
| C1 | Agent creation, instructions / system prompt |
| C2 | AI Search knowledge source binding via a Power Platform data connection (Entra ID Integrated or Service principal — never Access Key); vector index `idx-rag-documents` |
| C3 | Grounding configuration — turn **Allow the AI to use its own general knowledge** off (Overview page) and **Allow ungrounded responses** off (Generative AI settings) |
| C4 | Test pane validation across factual / paraphrased / multi-doc / out-of-corpus questions |
| C5 | Publish the agent and add the **Teams and Microsoft 365 Copilot** channel (single combined channel); set Availability options for the right audience |
| C6 | End-user validation from Teams + M365 Copilot |

### Option D-FA — Microsoft Foundry agent (alternative)

Built on the Foundry Agent Service runtime, grounding on the **same** `idx-rag-documents` index plus an optional **Fabric Data Agent** for structured data (built per **[03e-fabric-data-agent.md](./03e-fabric-data-agent.md)**), published to Teams + M365 Copilot as a **custom engine agent (preview)**. Full step-by-step: **[03d-foundry-agent-setup.md](./03d-foundry-agent-setup.md)**.

What 03d covers end-to-end (Phases D0–D6):

| 03d Phase | What you build |
|---|---|
| D0 | Prerequisites + the **licensing delta**; chat-model deployment becomes **required**; publish the Fabric Data Agent ([03e](./03e-fabric-data-agent.md)) |
| D1 | Foundry project + chat (`gpt-4o`) deployment |
| D2 | AI Search tool connection — project MI granted **Search Index Data Reader** |
| D3 | Fabric Data Agent tool — **on-behalf-of** caller identity (per-user RLS) |
| D4 | Agent instructions, grounding guardrail, security trimming |
| D5 | Test in the Foundry playground |
| D6 | Publish to M365 Copilot + Teams via the M365 Agents Toolkit (**preview**), **or** deploy the in-repo standalone web app front end ([09](./09-foundry-agent-webapp.md); MI or OBO mode) |

### Part D validation

> Run the checklist for whichever option you built. The 03d-specific checklist is in [03d § Validation checklist](./03d-foundry-agent-setup.md#validation-checklist). The boxes below are written for the 03c (Copilot Studio) path.

- [ ] Knowledge source bound to `idx-rag-documents` via **Microsoft Entra ID Integrated** or **Service principal** (not Access Key) and showing **Status: Ready** ([03c § C2](./03c-copilot-studio-setup.md#phase-c2--bind-the-ai-search-knowledge-source))
- [ ] Both **Allow the AI to use its own general knowledge** and **Allow ungrounded responses** are **Off** ([03c § C3](./03c-copilot-studio-setup.md#phase-c3--configure-grounding-behavior))
- [ ] Test pane returns grounded answers with citations to Blob source files ([03c § C4](./03c-copilot-studio-setup.md#phase-c4--test-in-the-agent-canvas))
- [ ] Agent published; **Teams and Microsoft 365 Copilot** channel added with **Make agent available in Microsoft 365 Copilot** selected
- [ ] Agent reachable in Teams chat AND in Microsoft 365 Copilot as a normal user (not just the builder)
- [ ] End-to-end: question in Teams → answer with clickable citation → opens raw file in Blob

---

## Part E — Run the test suite

Once Parts A–D validate green, follow [05-testing.md](./05-testing.md):

### E1. Run the index quality smoke tests (§ B)
### E2. Run the golden-set retrieval evaluation (§ C)
### E3. Run the semantic-ranker A/B comparison (§ D) — document the lift for your stakeholders

### Part E validation

- [ ] `recall@5 (doc)` ≥ 0.85 on golden set
- [ ] Semantic ranker lift over hybrid-only is measurable (target: +10pp recall, +0.15 MRR)
- [ ] End-to-end demo script (§ E in testing) rehearsed cleanly

---

## Part F — Wire ADO (if using automated path with CI/CD)

1. Push this repo to your ADO project (`https://dev.azure.com/<org>/<project>/_git/rag-knowledge-base-pattern`)
2. Create variable group `rag-kb-env-dev` with the per-environment Bicep parameters
3. Create environment `rag-kb-dev` for deployment gating
4. Register the pipeline at `.azuredevops/pipelines/deploy-rag-kb.yml`
5. Configure a service connection to Azure (preferably workload identity federation)
6. Run the pipeline once manually to confirm; subsequent deployments are triggered on push to `dev` / `prod`

---

## Single-page checklist

| Part | What | Done |
|---|---|---|
| Prereqs | All boxes in § Prerequisites checklist confirmed | [ ] |
| A | Deployment path chosen (manual or Bicep) | [ ] |
| B | Azure platform layer deployed; AI Search indexer succeeded | [ ] |
| C | Fabric workspace + Lakehouse + pipeline built; control table populated | [ ] |
| D | Agent built (Copilot Studio **or** Foundry) + published to Teams + M365 Copilot | [ ] |
| E | Golden-set retrieval evaluation passing thresholds | [ ] |
| F | (Optional) ADO pipeline wired for CI/CD | [ ] |

---

*Last updated: 2026-06-09*

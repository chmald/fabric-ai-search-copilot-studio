# 00 — Reproduce this demo

> **Audience.** Someone who wants to clone this repo and stand up the full RAG knowledge-base demo against a fresh Azure subscription + Fabric tenant + Copilot Studio environment. Each Part below is a discrete checkpoint — finish A before starting B, etc. The deep-dive runbooks ([03-deployment-manual.md](03-deployment-manual.md), [03b-fabric-setup.md](03b-fabric-setup.md), [04-deployment-automated.md](04-deployment-automated.md), [05-testing.md](05-testing.md), [06-troubleshooting.md](06-troubleshooting.md)) are linked from the specific steps that consume them rather than duplicated here.

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
│   │     └─ chat deployment:      gpt-4o                                 │
│   ├─ Document Intelligence di-rag-dev-eastus2                           │
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
│   ├─ Pipeline (parent): pl_ingest_docs (lookup + ForEach)               │
│   └─ Pipeline (child):  pl_process_file (Copy → DI → chunk → Blob)      │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ AI Search knowledge source               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Copilot Studio                                                          │
│   Agent: agent-rag-kb                                                   │
│   ├─ Knowledge: idx-rag-documents (Azure AI Search, semantic search ON) │
│   └─ Channels:  Microsoft Teams + M365 Copilot                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites checklist (verify before starting Part A)

- [ ] **Azure subscription** with Contributor + User Access Administrator on the target RG (or subscription scope for greenfield)
- [ ] **Region chosen** from [02-prerequisites.md § 11](./02-prerequisites.md) Tier-1 list — default: **East US 2** for US, **Sweden Central** for EU, **Australia East** / **Japan East** for APAC
- [ ] **Azure OpenAI access approved** in the subscription with TPM quota for `text-embedding-3-large` (10K TPM minimum for demo) and `gpt-4o` (10K TPM minimum)
- [ ] **Fabric capacity** allocated (F4+ for demo, F16+ for production) and a workspace where you have Admin or Member role
- [ ] **Copilot Studio license** for the building user — and channel-publishing pre-approvals **initiated** (Teams + M365 Copilot admin approvals take ~1-2 business days)
- [ ] **Local tools**: `git`, `pwsh` 7+, **Python 3.11+**, **Azure CLI 2.60+** with the `bicep` extension installed (`az bicep install`)
- [ ] **(For automated path only)** Ability to authenticate to Azure with an identity that has the role assignments above (e.g. `az login` with your user, or a service principal for ADO)

If any of these are missing, see [02-prerequisites.md](./02-prerequisites.md) for the full breakdown.

---

## Part A — Choose your deployment path

Two paths produce the same end-state:

| Path | When to use | Doc |
|---|---|---|
| **A1. Manual / portal + CLI** | Learning the architecture; one-off demo labs; first time you touch this pattern | [03-deployment-manual.md](./03-deployment-manual.md) |
| **A2. Automated / Bicep** | Repeated deployments; CI/CD; multiple environments (dev/prod); production stand-up | [04-deployment-automated.md](./04-deployment-automated.md) |

Both paths skip Fabric workspace creation and Copilot Studio agent configuration in their respective deep-dives — Fabric is **always manual** (no Bicep / IaC surface today) and lives in its own document ([03b-fabric-setup.md](./03b-fabric-setup.md)); Copilot Studio is covered below in Part D. Both are identical regardless of which Azure path you chose in A1 / A2.

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
| F4 | OneLake shortcut to the customer source (SharePoint / ADLS / S3 / etc.) |
| F5 | Control `control_table_files` Delta table |
| F6 | Fabric connections to Key Vault and Blob Storage |
| F7 | Three pipeline notebooks (lookup, chunk+upload, control-table upsert) |
| F8 | Data Pipelines: parent `pl_ingest_docs` (lookup + ForEach) and child `pl_process_file` (per-file Copy + DI + chunk + control updates). Two pipelines are required because Fabric does not allow `Until` inside `ForEach`. |
| F9 | End-to-end validation on sample docs |
| F10 | Pipeline schedule |

### Part C validation

- [ ] Workspace + Lakehouse + workspace identity created ([03b §§ F1–F3](./03b-fabric-setup.md))
- [ ] OneLake shortcut populated with sample documents ([03b § F4](./03b-fabric-setup.md#phase-f4--attach-the-source-via-onelake-shortcut))
- [ ] Pipeline succeeds end-to-end on sample docs ([03b § F9](./03b-fabric-setup.md#phase-f9--validate-end-to-end))
- [ ] Control table has rows with `ocr_status = succeeded` and `chunk_status = succeeded`
- [ ] Blob `chunks/` container has JSON files; AI Search indexer picks them up within ~5 min

---

## Part D — Build the Copilot Studio agent (manual — both paths)

Copilot Studio agents are not expressible in Bicep (Power Platform, not Azure). Follow [03-deployment-manual.md § Phase 5](./03-deployment-manual.md):

### D1. Create the agent + bind the knowledge source

1. Copilot Studio → **Create → Agent** → name `agent-rag-kb`
2. **Knowledge → + Add knowledge → Azure AI Search**
3. **Search endpoint:** `https://srch-rag-<env>-<region>.search.windows.net`
4. **Index name:** `idx-rag-documents`
5. **Enable semantic search:** **ON** ← critical
6. **Title field:** `doc_id`, **URL field:** `source_uri`, **Content field:** `content`
7. **Generative AI → Settings → Knowledge source = AI Search**, **Generative answers: Enabled**

### D2. Test in the agent canvas

Use the **Test** pane to ask a few questions across factual / semantic / multi-doc / out-of-corpus categories per [05-testing.md § E2](./05-testing.md).

### D3. Publish to Teams + M365 Copilot

1. **Publish → Channels → Microsoft Teams** (admin approval if not already cleared)
2. **Publish → Channels → Microsoft 365 Copilot** (admin approval if not already cleared)

### Part D validation

- [ ] Test pane returns grounded answers with citations to Blob source files
- [ ] Teams channel published; agent reachable in Teams chat
- [ ] M365 Copilot channel published; agent appears in M365 Copilot agent gallery
- [ ] End-to-end: question in Teams → answer with clickable citation → opens raw file in Blob

---

## Part E — Run the test suite

Once Parts A–D validate green, follow [05-testing.md](./05-testing.md):

### E1. Run the index quality smoke tests (§ B)
### E2. Run the golden-set retrieval evaluation (§ C)
### E3. Run the semantic-ranker A/B comparison (§ D) — document the lift for your customer

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
| D | Copilot Studio agent built + published to Teams + M365 Copilot | [ ] |
| E | Golden-set retrieval evaluation passing thresholds | [ ] |
| F | (Optional) ADO pipeline wired for CI/CD | [ ] |

---

*Last updated: 2026-05-22*

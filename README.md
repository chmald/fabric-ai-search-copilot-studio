# Reusable RAG Knowledge-Base Pattern

A reusable, low-code-first **Retrieval-Augmented Generation (RAG) knowledge-base** pattern for grounding a Copilot Studio agent on a customer document corpus. This folder is the canonical reference for **demo build + production replication**.

> **Generic on purpose.** This pattern is document-domain agnostic. Use it for HR contracts, finance policies, legal templates, support knowledge bases, product docs, sales enablement libraries, or any unstructured document corpus that needs to power a grounded chat experience.

---

## What this pattern delivers

A working end-to-end RAG agent that:

- Ingests an unstructured document corpus from **Fabric OneLake** (or any Fabric-attached source)
- OCRs documents with **Azure Document Intelligence** `prebuilt-read` (served by the same Azure AI Foundry resource as the OpenAI models — no separate FormRecognizer resource is provisioned)
- Chunks text and writes to **Azure Blob Storage** as the permanent canonical store
- Indexes content in **Azure AI Search** using **integrated vectorization** (no custom embedding code) into a **hybrid index** (keyword + vector + metadata)
- Re-ranks results with the **AI Search semantic ranker** for production-grade relevance
- Surfaces answers through a **Copilot Studio agent** published to **Microsoft Teams** and **M365 Copilot** — Copilot Studio uses its own host LLM for generative answers, so the Foundry resource only needs the embedding model by default (the chat deployment in [`infra/main.bicep`](./infra/main.bicep) is opt-in for engagement-specific extensions; see the Foundry note below)

The pattern is intentionally low-code: every step is either a no-code Azure/Fabric portal configuration, a drag-and-drop Fabric Data Pipeline activity, or a Copilot Studio configuration screen. **No application code is required for this pattern.**

---

## Locked design decisions

These are the design decisions locked for this pattern's primary use case — single-purpose knowledge-base Q&A over a document corpus. Deviate only with an explicit decision record describing the engagement-specific need and updated guidance.

| # | Decision | Choice | Why |
|---|---|---|---|
| 1 | Orchestration layer | **Copilot Studio native** (no Foundry / no custom orchestrator) | Lowest-code path; Copilot Studio's native AI Search knowledge source handles retrieval, grounding, and citation |
| 2 | Vectorization | **AI Search integrated vectorizer** (Foundry-hosted OpenAI embedding) | Index-time + query-time embedding handled by AI Search; eliminates custom embedding code in the pipeline |
| 3 | Index type | **Hybrid** (BM25 keyword + vector) | Hybrid retrieval consistently beats vector-only on factual / exact-match queries (IDs, dates, names, dollar amounts) |
| 4 | Semantic ranker | **Enabled** | Second-stage re-ranker delivers 25–50 % relevance lift on Q&A workloads; required for production-grade citation quality |
| 5 | Storage split | **OneLake = source / staging, Blob = permanent + indexed** | Reuses customer's existing Fabric investment for ingestion; Blob is cheaper, easier to secure, and is the simplest source for the AI Search indexer |
| 6 | Pipeline orchestrator | **Fabric Data Pipelines** | Drag-and-drop, native to Fabric, no extra service to license |
| 7 | Ingestion control | **Fabric Lakehouse Delta table** | Tracks file metadata, processing state, and run history for idempotency + incremental processing |
| 8 | OCR | **Document Intelligence prebuilt-read** model, served by the **Azure AI Foundry resource** (`kind=AIServices`) | No model training; handles printed + handwritten text, multiple languages, mixed file types. A Foundry resource is a multi-service Cognitive Services account, so the same resource provisioned for OpenAI deployments also exposes the DI endpoint — no separate `FormRecognizer` resource is needed |
| 9 | Front-end channels | **Teams + M365 Copilot** | Two native channels with zero additional hosting; demo-ready in minutes |
| 10 | AI Search tier | **Standard (S1) or higher** | Required for semantic ranker; provides headroom for production scale |

See [docs/01-architecture.md](./docs/01-architecture.md) for the full design narrative and trust boundaries.

---

## File index

| File | Purpose |
|---|---|
| [README.md](./README.md) | Pattern overview + locked decisions + file index (this file) |
| [docs/00-reproduce-this-demo.md](./docs/00-reproduce-this-demo.md) | **Start here.** Single-page orchestrator with Parts A–F + time budget + end-state diagram |
| [docs/01-architecture.md](./docs/01-architecture.md) | Full reference architecture: diagram, components, data flow, trust boundaries, decisions |
| [docs/02-prerequisites.md](./docs/02-prerequisites.md) | Subscriptions, licensing, RBAC, model availability + regional matrix, quotas, naming conventions |
| [docs/03-deployment-manual.md](./docs/03-deployment-manual.md) | Manual / portal + CLI walkthrough — **Azure platform layer only** (Phase 1 foundation, Phase 4 AI Search index); best for first-time learning |
| [docs/03b-fabric-setup.md](./docs/03b-fabric-setup.md) | **Fabric setup (always manual)** — workspace, identity, Lakehouse, OneLake shortcut, control table, connections, ingest pipeline. Required after either Azure deployment path. |
| [docs/03c-copilot-studio-setup.md](./docs/03c-copilot-studio-setup.md) | **Copilot Studio setup (always manual)** — agent creation, AI Search knowledge source, generative answers, Teams + M365 Copilot publishing. Final step after Azure + Fabric. |
| [docs/04-deployment-automated.md](./docs/04-deployment-automated.md) | Automated path — Bicep + post-deploy script + ADO pipeline for the **Azure layer**; Fabric still uses 03b, Copilot Studio still uses 03c |
| [docs/05-testing.md](./docs/05-testing.md) | Functional tests, retrieval quality, semantic-ranker validation, end-to-end demo script |
| [docs/06-troubleshooting.md](./docs/06-troubleshooting.md) | Common failure modes and fixes |
| `infra/main.bicep` + `infra/modules/*.bicep` | Bicep IaC for all Azure resources (RG, KV, Storage, Foundry + model deployments + built-in Document Intelligence, AI Search, RBAC) |
| `infra/main.parameters.json` | Bicep parameters template — copy to `main.parameters.local.json` for your values (gitignored) |
| `infra/deploy.ps1` | PowerShell wrapper for `az deployment sub create` + output capture |
| `scripts/post_deploy_search.py` | Creates AI Search index, data source, and indexer with integrated AOAI vectorizer (Bicep can't express these cleanly) |
| `scripts/requirements.txt` | Python dependencies for `scripts/` and `tests/` |
| `scripts/tests/` | Smoke tests for the post-deploy script |
| `.azuredevops/pipelines/deploy-rag-kb.yml` | CI/CD pipeline: Validate → Deploy → Smoke |
| `.gitignore` | Excludes secrets, venvs, populated demo-ids, IDE state from ADO commits |
| `demo-ids.template.json` | Reference template for per-deployment IDs. The live file (`demo-ids.local.json`, gitignored) is **hybrid**: top-level Azure fields are auto-written by `infra/deploy.ps1` from the Bicep `deploymentSummary` and overwritten on every deploy; nested objects (`fabric`, `sp-rag-di-caller`, `copilotStudio`) are populated manually during the Fabric / Copilot Studio setup phases and preserved across deploys (`deploy.ps1` merges rather than overwrites). The template's `_meta` block documents the contract — copy it to `demo-ids.local.json` to scaffold a new environment. Never commit a populated copy. |

Read in order on first build. After that, treat them as a reference set.

---

## Quick-start prerequisites at a glance

You will need (full detail in [docs/02-prerequisites.md](./docs/02-prerequisites.md)):

- **Azure subscription** with Contributor + User Access Administrator on the target resource group
- **Microsoft Fabric tenant** with a workspace you can create artifacts in (Lakehouse + Data Pipelines)
- **Copilot Studio license** for the building user (Maker access)
- **Azure AI Foundry resource** (the unified Azure AI Services resource, `kind=AIServices`) with capacity for **one embedding deployment** (e.g. `text-embedding-3-large`). A chat completion deployment (e.g. `gpt-4o`) is **opt-in** — the locked design (Copilot Studio + AI Search + integrated vectorizer) does not consume a chat completion model; Copilot Studio uses its own host model for generative answers. The same Foundry resource also exposes **Document Intelligence** (`prebuilt-read` OCR) from its built-in Cognitive Services surface — no separate Document Intelligence / FormRecognizer resource is required. Foundry is the strategic model-gateway resource and supersedes the legacy standalone Azure OpenAI resource for new deployments.
- **Region alignment**: all services (AI Search, Azure AI Foundry — which hosts both the OpenAI models and the Document Intelligence OCR endpoint — Blob, Fabric) ideally in the **same Azure region**, or at least the same data residency boundary
- **AI Search**: **Standard (S1) or higher** SKU (semantic ranker is not available on Basic)
- **Local developer tooling**: **PowerShell 7+ (`pwsh`)**, **Azure CLI 2.60+** (with the `bicep` extension: `az bicep install`), **Python 3.11+**, and `git`. **All shell snippets in this repo are written in PowerShell**, the deployment wrapper is `infra/deploy.ps1`, and the docs assume you're running `pwsh` — see [Shell convention](#shell-convention) below.

---

## Shell convention

**All shell code blocks in this repo (and in `docs/*.md`) are PowerShell.** They're tagged ```` ```pwsh ```` for syntax highlighting and are designed to be copy-pasteable into a `pwsh` 7+ session on Windows, macOS, or Linux. Conventions used throughout:

| What you'll see | Why |
|---|---|
| `$VAR = "value"` and `$VAR = az ... -o tsv` | PowerShell variable assignment (no `VAR=value` bash form) |
| Backtick `` ` `` at end of line | PowerShell line continuation (no `\` bash form) |
| `curl.exe ...` (not bare `curl`) | Disambiguates from older Windows PowerShell where `curl` was an alias for `Invoke-WebRequest`; `curl.exe` always invokes the real curl binary that ships with Windows 10+ |
| `Invoke-RestMethod \| Select-Object …` | Native PowerShell JSON handling — **no `jq` dependency** required anywhere in the docs |
| `pwsh ./infra/deploy.ps1 ...` | The deployment wrapper. Use `./infra/deploy.ps1 -WhatIf` for a dry run, `-Verify` to run smoke tests, `-RestoreFoundry` to recover from a soft-deleted Foundry account |

If you prefer `bash` for ad-hoc Azure CLI work, the `az` commands themselves are identical — you'd just need to convert `$VAR = "value"` → `VAR=value` and backtick → `\` for line continuation. The Bicep deploys (`az deployment sub create`) and the post-deploy Python script (`scripts/post_deploy_search.py`) are shell-agnostic.

---

## When to use this pattern (and when not to)

### Use this pattern when

- The customer wants a grounded conversational agent over an unstructured document corpus (PDFs, Word docs, scanned files)
- Low-code or no-code delivery is required or strongly preferred
- The customer already has or is comfortable adopting Microsoft Fabric for ingestion / staging
- The corpus is in the low-thousands to low-hundreds-of-thousands of documents range
- Document content can be addressed by retrieval (Q&A, summarization, citation) — not field extraction into structured records

### Use a different pattern when

- The customer needs **structured field extraction** into a database (e.g. invoice line items, contract clauses into rows) → use a Document Intelligence custom-extraction model + Fabric / SQL pipeline instead
- The customer needs **multi-agent orchestration** with custom triage, routing, or tool-calling logic → add **Azure AI Foundry agent runtime** as an additional orchestration layer above this pattern's components (out of scope for this pattern as written)
- The corpus is in the **millions of documents** with stringent low-latency requirements → revisit index sharding, replica counts, and tier selection beyond Standard
- The customer requires a **non-OpenAI model** (Cohere, Llama, Phi, Mistral, etc.) → Foundry resource supports these via its model catalog, but the AI Search `azureOpenAI` vectorizer is OpenAI-only; non-OpenAI embedding requires the AML-hosted vectorizer kind (out of scope for this pattern as written)

---

## Note on Azure AI Foundry — model gateway, Document Intelligence, and agent runtime

This pattern uses an **Azure AI Foundry resource** (`kind=AIServices`) as the **multi-service Cognitive Services account** that hosts:

- the OpenAI embedding + chat deployments used by the AI Search vectorizer and Copilot Studio, and
- the **Document Intelligence** `prebuilt-read` endpoint used by the Fabric OCR notebook (same resource ID, same managed identity, same RBAC surface — just a different host: `<foundry>.cognitiveservices.azure.com` for DI vs `<foundry>.openai.azure.com` for OpenAI).

It does **not** use Foundry's agent runtime (Agent Service, Hub, Projects) — that role is filled by Copilot Studio's native AI Search knowledge source. Foundry's capabilities are independent and chosen per engagement need:

| Foundry capability | Recommendation | When to use |
|---|---|---|
| **Model gateway + Document Intelligence** (Azure AI Foundry resource hosting OpenAI + catalog models + the Cognitive Services API surface including DI prebuilt-read) | **Default for this pattern** | The strategic Azure direction for all new AI model deployments; single multi-service account avoids a separate FormRecognizer resource and a duplicate managed identity; same OpenAI-compatible endpoint as legacy standalone AOAI; flexibility to add non-OpenAI catalog models later under one resource |
| **Agent runtime** (Foundry Agent Service / Hub / Projects) | **Add when needed** | When the agent must do **more than knowledge-base Q&A** — multi-agent routing, custom tool calling, query triage logic, or non-standard grounding. For pure knowledge-base Q&A — the focus of this pattern — Copilot Studio's native AI Search knowledge source delivers retrieval + grounding + citation without code. Adding Foundry agent runtime is an additional infrastructure + code layer; only adopt it when an engagement need demands it. |

---

## Deployment paths

Two paths produce the same end-state for the **Azure platform layer**:

| Path | Best for | Doc |
|---|---|---|
| **Manual** — portal + CLI walkthrough | Learning the architecture; one-off demo labs; first time with this pattern | [docs/03-deployment-manual.md](./docs/03-deployment-manual.md) |
| **Automated** — Bicep + post-deploy script | Repeated deployments; CI/CD; dev + prod environment parity | [docs/04-deployment-automated.md](./docs/04-deployment-automated.md) |

**Both paths require [docs/03b-fabric-setup.md](./docs/03b-fabric-setup.md) for the Fabric layer and [docs/03c-copilot-studio-setup.md](./docs/03c-copilot-studio-setup.md) for the Copilot Studio agent**. Both Fabric and Copilot Studio are always manual — Fabric workspaces, Lakehouses, OneLake shortcuts, and Data Pipelines have no Bicep/Terraform surface today, and Copilot Studio is Power Platform (not Azure) with no IaC surface. [docs/00-reproduce-this-demo.md](./docs/00-reproduce-this-demo.md) is the orchestrator that walks all three layers (Azure platform → Fabric → Copilot Studio) through Parts A–F.

---

## Distribution

This Demos folder is intended to be **checked into Azure DevOps** as a standalone repo in your tenant (typical: `https://dev.azure.com/<org>/<project>/_git/rag-knowledge-base-pattern`). The included `.gitignore` and `demo-ids.template.json` are scaffolded for that workflow:

- **`.gitignore`** — excludes secrets (`*.pem`, `*.key`, `.sp-secret.json`, `secrets.json`), the populated copy of demo-ids (`demo-ids.local.json`), Python venvs, IDE state, and local deployment artifacts.
- **`demo-ids.template.json`** — reference template for the per-deployment IDs file. The live file (`demo-ids.local.json`, gitignored) is **hybrid**: `infra/deploy.ps1` auto-writes the Azure resource IDs / endpoints / MI object IDs from the Bicep `deploymentSummary` output on every successful deploy, and *merges* (rather than overwrites) — so nested objects you populate manually during the Fabric and Copilot Studio setup phases (`fabric`, `sp-rag-di-caller`, `copilotStudio`) survive subsequent redeploys. The `_meta` block in both files documents the contract. **Never commit a populated `demo-ids.local.json` or any secret material.**
- **Runtime values** (per-environment workspace IDs, endpoints) should come from your CI tool's secret store (ADO variable groups / GitHub Actions secrets / Key Vault), not from the repo.

---

## Decision provenance

| Date | Decision | Reference |
|---|---|---|
| 2026-05-21 | Locked architecture decisions: Copilot Studio orchestration for knowledge-base Q&A, Foundry as model gateway, integrated vectorizer, hybrid + semantic ranker, OneLake + Blob storage, Fabric Data Pipelines | the CHANGELOG entry |
| 2026-05-22 | Artifact restructure: docs/ folder layout, Bicep IaC + 5 modules, dual deployment path (manual + automated), ADO pipeline | the CHANGELOG entry |
| 2026-05-25 | **Document Intelligence consolidated into the Azure AI Foundry resource.** Removed the standalone `Microsoft.CognitiveServices/accounts` of `kind=FormRecognizer` (and its `modules/docintelligence.bicep` module + its dedicated managed identity + duplicate Storage Blob Data Reader role assignment). DI is now served by the Foundry account (`kind=AIServices` is a multi-service Cognitive Services account). Net result: 4 Azure resources instead of 5, single MI for both OpenAI and DI storage access, single RBAC surface. See [docs/01-architecture.md § 8](./docs/01-architecture.md#8-document-intelligence-prebuilt-read-served-by-the-foundry-resource) for the design rationale. |
| 2026-05-25 | **AI Search Bicep auth fix.** Removed the `authOptions: { aadOrApiKey: ... }` block from `modules/search.bicep` — the Azure Search API treats `authOptions` and `disableLocalAuth: true` as mutually exclusive (`BadRequest: AuthOptions must be null if DisableLocalAuth is true`). Bearer challenges still work by default when local auth is disabled. See [docs/06-troubleshooting.md § 0.4](./docs/06-troubleshooting.md#04-bicep-deploy-fails-authoptions-must-be-null-if-disablelocalauth-is-true). |
| 2026-05-26 | **Chat completion deployment made opt-in.** Changed `chatModelName` default from `gpt-4o` to `''` in `infra/main.bicep` and `main.parameters.json`. The `chatDeployment` resource in `modules/aifoundry.bicep` is now wrapped in `if (!empty(chatModelName))`. Rationale: an audit found that no code path in the locked design consumes the chat completion model — `scripts/post_deploy_search.py` only references the embedding deployment, the Fabric OCR notebook only calls Document Intelligence, AI Search vectorizer/skillset only embed, and Copilot Studio's generative answers run on its own host model (the M365 Copilot model). The `gpt-4o` deployment was provisioned just-in-case and consumed 10K TPM of subscription quota for no benefit. Opt in by setting `chatModelName` to `gpt-4o` (or `gpt-4o-mini`) when an engagement explicitly needs a chat endpoint (custom app code, Foundry agent runtime, Copilot Studio bring-your-own-model). The `deploymentSummary` Bicep output now also emits a `chatDeployed: bool` flag so tooling can branch on it. |
| 2026-05-26 | **Soft-delete restore for Foundry resource (opt-in pattern).** Added an opt-in `restoreFoundryFromSoftDelete` Bicep parameter (default `false`) and a matching `-RestoreFoundry` switch on `infra/deploy.ps1`. When the param is `true`, `infra/modules/aifoundry.bicep` adds `properties.restore: true` to the Foundry account via `union()`; otherwise the property is omitted. Rationale: an always-on `restore: true` was tried first but rejected by the Cognitive Services ARM provider on fresh creates with `CanNotRestoreANonExistingResource: Could not locate a resource to restore`. The opt-in pattern is the correct stable shape — fresh deploys are unaffected, and operators recover from `FlagMustBeSetForRestore` by re-running `pwsh ./infra/deploy.ps1 -RestoreFoundry`. Preserving the MI matters because the DI-caller SP's `Cognitive Services User` role assignment on the Foundry resource is granted manually (per [docs/03b-fabric-setup.md § F2.2 step 2](./docs/03b-fabric-setup.md)) and would be orphaned by any purge-and-recreate cycle. See [docs/06-troubleshooting.md § 0.5](./docs/06-troubleshooting.md#05-bicep-deploy-fails-flagmustbesetforrestore-soft-deleted-foundry--cognitive-services-account). |
| 2026-05-26 | **Deployer Key Vault Secrets Officer grant added to Bicep.** `infra/modules/rbac.bicep` now grants `deployerPrincipalId` the **Key Vault Secrets Officer** role on the Key Vault (gated by the same `!empty(deployerPrincipalId)` check as the Search role grants). Without this, the operator hits `403 Forbidden` on `az keyvault secret set` when storing the DI-caller SP secret in [docs/03b-fabric-setup.md § F2.2 step 3](./docs/03b-fabric-setup.md). The manual path in [docs/03-deployment-manual.md §§ 1.2 and 1.7](./docs/03-deployment-manual.md) now includes the explicit `az role assignment create` command for the same grant. |

---

*Last updated: 2026-05-26*

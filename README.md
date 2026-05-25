# Reusable RAG Knowledge-Base Pattern

A reusable, low-code-first **Retrieval-Augmented Generation (RAG) knowledge-base** pattern for grounding a Copilot Studio agent on a customer document corpus. This folder is the canonical reference for **demo build + production replication**.

> **Generic on purpose.** This pattern is document-domain agnostic. Use it for HR contracts, finance policies, legal templates, support knowledge bases, product docs, sales enablement libraries, or any unstructured document corpus that needs to power a grounded chat experience.

---

## What this pattern delivers

A working end-to-end RAG agent that:

- Ingests an unstructured document corpus from **Fabric OneLake** (or any Fabric-attached source)
- OCRs documents with **Azure Document Intelligence** (prebuilt-read model)
- Chunks text and writes to **Azure Blob Storage** as the permanent canonical store
- Indexes content in **Azure AI Search** using **integrated vectorization** (no custom embedding code) into a **hybrid index** (keyword + vector + metadata)
- Re-ranks results with the **AI Search semantic ranker** for production-grade relevance
- Surfaces answers through a **Copilot Studio agent** published to **Microsoft Teams** and **M365 Copilot**

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
| 8 | OCR | **Document Intelligence prebuilt-read** model | No model training; handles printed + handwritten text, multiple languages, mixed file types |
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
| `demo-ids.template.json` | Reference template for per-deployment IDs. Copy to `demo-ids.local.json` after deployment; never commit populated copies. |

Read in order on first build. After that, treat them as a reference set.

---

## Quick-start prerequisites at a glance

You will need (full detail in [docs/02-prerequisites.md](./docs/02-prerequisites.md)):

- **Azure subscription** with Contributor + User Access Administrator on the target resource group
- **Microsoft Fabric tenant** with a workspace you can create artifacts in (Lakehouse + Data Pipelines)
- **Copilot Studio license** for the building user (Maker access)
- **Azure AI Foundry resource** (the unified Azure AI Services resource) with capacity for one chat completion deployment (e.g. `gpt-4o`) and one embedding deployment (e.g. `text-embedding-3-large`) — Foundry is the strategic model-gateway resource and supersedes the legacy standalone Azure OpenAI resource for new deployments
- **Region alignment**: all services (AI Search, Azure AI Foundry — which hosts both the OpenAI models and the Document Intelligence OCR endpoint — Blob, Fabric) ideally in the **same Azure region**, or at least the same data residency boundary
- **AI Search**: **Standard (S1) or higher** SKU (semantic ranker is not available on Basic)

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

## Note on Azure AI Foundry — model gateway vs agent runtime

This pattern uses an **Azure AI Foundry resource** as the **model-hosting gateway** (where the OpenAI embedding + chat deployments live). It does **not** use Foundry's agent runtime (Agent Service, Hub, Projects) — that role is filled by Copilot Studio's native AI Search knowledge source. Foundry's two capabilities are independent and chosen per engagement need:

| Foundry capability | Recommendation | When to use |
|---|---|---|
| **Model gateway** (Azure AI Foundry resource hosting OpenAI + catalog models) | **Default for OpenAI hosting** | The strategic Azure direction for all new AI model deployments; same OpenAI-compatible endpoint as legacy standalone AOAI resource; provides flexibility to add non-OpenAI catalog models later under one resource |
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
- **`demo-ids.template.json`** — reference template for the resource IDs (workspace, capacity, search service, Foundry resource, etc.) you'll have after a real deployment. Copy to `demo-ids.local.json` after deploying and populate; that local copy is gitignored. **Never commit a populated `demo-ids.json` or any secret material.**
- **Runtime values** (per-environment workspace IDs, endpoints) should come from your CI tool's secret store (ADO variable groups / GitHub Actions secrets / Key Vault), not from the repo.

---

## Decision provenance

| Date | Decision | Reference |
|---|---|---|
| 2026-05-21 | Locked architecture decisions: Copilot Studio orchestration for knowledge-base Q&A, Foundry as model gateway, integrated vectorizer, hybrid + semantic ranker, OneLake + Blob storage, Fabric Data Pipelines | the CHANGELOG entry |
| 2026-05-22 | Artifact restructure: docs/ folder layout, Bicep IaC + 5 modules, dual deployment path (manual + automated), ADO pipeline | the CHANGELOG entry |

---

*Last updated: 2026-05-22*

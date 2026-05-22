# Reusable RAG Knowledge-Base Pattern (Low-Code v1)

A reusable, low-code-first **Retrieval-Augmented Generation (RAG) knowledge-base** pattern for grounding a Copilot Studio agent on a customer document corpus. This folder is the canonical reference for **demo build + production replication**.

> **Generic on purpose.** This pattern is document-domain agnostic. Use it for HR contracts, finance policies, legal templates, support knowledge bases, product docs, sales enablement libraries, or any unstructured document corpus that needs to power a grounded chat experience.

---

## What this pattern delivers

A working end-to-end RAG agent that:

- Ingests an unstructured document corpus from **Fabric OneLake** (or any Fabric-attached source)
- OCRs documents with **Azure Document Intelligence** (prebuilt-read model)
- Chunks text and writes to **Azure Blob Storage** as the permanent canonical store
- Indexes content in **Azure AI Search** using **integrated AOAI vectorization** (no custom embedding code) into a **hybrid index** (keyword + vector + metadata)
- Re-ranks results with the **AI Search semantic ranker** for production-grade relevance
- Surfaces answers through a **Copilot Studio agent** published to **Microsoft Teams** and **M365 Copilot**

The pattern is intentionally low-code: every step is either a no-code Azure/Fabric portal configuration, a drag-and-drop Fabric Data Pipeline activity, or a Copilot Studio configuration screen. **No application code is required for v1.**

---

## Locked design decisions

These decisions are **the v1 baseline**. Deviate only with an explicit decision record and updated guidance.

| # | Decision | Choice | Why |
|---|---|---|---|
| 1 | Orchestration layer | **Copilot Studio native** (no Foundry / no custom orchestrator) | Lowest-code path; Copilot Studio's native AI Search knowledge source handles retrieval, grounding, and citation |
| 2 | Vectorization | **AI Search integrated AOAI vectorizer** | Index-time + query-time embedding handled by AI Search; eliminates custom embedding code in the pipeline |
| 3 | Index type | **Hybrid** (BM25 keyword + vector) | Hybrid retrieval consistently beats vector-only on factual / exact-match queries (IDs, dates, names, dollar amounts) |
| 4 | Semantic ranker | **Enabled** | Second-stage re-ranker delivers 25–50 % relevance lift on Q&A workloads; required for production-grade citation quality |
| 5 | Storage split | **OneLake = source / staging, Blob = permanent + indexed** | Reuses customer's existing Fabric investment for ingestion; Blob is cheaper, easier to secure, and is the simplest source for the AI Search indexer |
| 6 | Pipeline orchestrator | **Fabric Data Pipelines** | Drag-and-drop, native to Fabric, no extra service to license |
| 7 | Ingestion control | **Fabric Lakehouse Delta table** | Tracks file metadata, processing state, and run history for idempotency + incremental processing |
| 8 | OCR | **Document Intelligence prebuilt-read** model | No model training; handles printed + handwritten text, multiple languages, mixed file types |
| 9 | Front-end channels | **Teams + M365 Copilot** | Two native channels with zero additional hosting; demo-ready in minutes |
| 10 | AI Search tier | **Standard (S1) or higher** | Required for semantic ranker; provides headroom for production scale |

See [01-architecture.md](./01-architecture.md) for the full design narrative and trust boundaries.

---

## File index

| File | Purpose |
|---|---|
| [README.md](./README.md) | Pattern overview + locked decisions + file index (this file) |
| [01-architecture.md](./01-architecture.md) | Full reference architecture: diagram, components, data flow, trust boundaries, decisions |
| [02-prerequisites.md](./02-prerequisites.md) | Subscriptions, licensing, RBAC, model availability, quotas, naming conventions |
| [03-deployment.md](./03-deployment.md) | Step-by-step build: foundation → ingestion → pipeline → index → agent → publish |
| [04-testing.md](./04-testing.md) | Functional tests, retrieval quality, semantic-ranker validation, end-to-end demo script |
| [05-troubleshooting.md](./05-troubleshooting.md) | Common failure modes and fixes |

Read in order on first build. After that, treat them as a reference set.

---

## Quick-start prerequisites at a glance

You will need (full detail in [02-prerequisites.md](./02-prerequisites.md)):

- **Azure subscription** with Contributor + User Access Administrator on the target resource group
- **Microsoft Fabric tenant** with a workspace you can create artifacts in (Lakehouse + Data Pipelines)
- **Copilot Studio license** for the building user (Maker access)
- **Azure OpenAI** access in your tenant with capacity for one chat completion deployment (e.g. `gpt-4o`) and one embedding deployment (e.g. `text-embedding-3-large`)
- **Region alignment**: all services (AI Search, AOAI, Document Intelligence, Blob, Fabric) ideally in the **same Azure region**, or at least the same data residency boundary
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
- The customer needs **multi-agent orchestration** with custom triage, routing, or tool-calling logic → add **Azure AI Foundry** as the orchestration layer (this pattern's v2)
- The corpus is in the **millions of documents** with stringent low-latency requirements → revisit index sharding, replica counts, and tier selection beyond Standard
- The customer requires a **bring-your-own** model or non-AOAI LLM → revisit the vectorizer + Copilot Studio model choices

---

## Pro-code alternative

For pro-code paths (custom Python ingestion, Bicep IaC, eval harness, custom field extraction), see the `chmald/document-intelligence-pattern` repository overlay model. This Demos folder is the **low-code companion**, not a replacement.

---

## Decision provenance

| Date | Decision | Reference |
|---|---|---|
| 2026-05-21 | Locked v1 reference architecture: Copilot Studio native + integrated vectorizer + hybrid + semantic ranker ON; no Foundry in v1 | the CHANGELOG entry |

---

*Last updated: 2026-05-21*

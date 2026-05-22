# 02 — Prerequisites

Everything required before you can start building. Work through this list in order; the deployment guide assumes all of these are in place.

> **Plan ahead.** Several items (Copilot Studio licensing, AOAI access approval, Fabric capacity allocation, AI Search tier selection) involve administrative approvals that can take hours to days. Start the slowest-moving ones first.

---

## 1 — Azure subscription

### Required

- An **Azure subscription** with **Contributor** + **User Access Administrator** rights on the resource group that will host the pattern
- Budget approval for the recurring monthly cost (rough estimate at the bottom of this page)

### Why both Contributor and User Access Administrator

Several integration points require **role assignments**, not just resource creation:

- Assigning managed identity → Storage Blob Data Reader on Blob
- Assigning AI Search managed identity → Cognitive Services OpenAI User on AOAI
- Assigning Fabric workspace identity → Blob Data Contributor on Blob

Contributor-only is **not enough**; you will hit "Authorization failed" errors when wiring up identities.

---

## 2 — Resource providers

In the target subscription, register these resource providers (one-time, takes a few minutes):

- `Microsoft.CognitiveServices` (Document Intelligence, Azure OpenAI)
- `Microsoft.Search`
- `Microsoft.Storage`
- `Microsoft.KeyVault`
- `Microsoft.Fabric` (if not auto-registered by the tenant)

```bash
# CLI check
az provider list --query "[?registrationState=='Registered'].namespace" -o tsv
```

If any are missing:

```bash
az provider register --namespace Microsoft.CognitiveServices --wait
```

---

## 3 — Azure OpenAI

### Required

- **AOAI resource** in the target subscription + region
- **Two model deployments:**
  - **Embedding** — recommended: `text-embedding-3-large` (3072 dim). Acceptable fallback: `text-embedding-3-small` (1536 dim) for cost-sensitive demos.
  - **Chat completion** — recommended: `gpt-4o`. Acceptable fallback: `gpt-4o-mini` for cost-sensitive demos.

### Region availability check

Not every model is available in every region. Confirm before provisioning:

- Microsoft Learn: "Azure OpenAI models and region availability" (search current Microsoft Learn — region matrix updates frequently)
- Or query the resource directly:

```bash
az cognitiveservices account list-models \
  --name <your-aoai-resource> \
  --resource-group <your-rg> \
  --query "[].{model:name, version:version, locations:capabilities.locations}"
```

### Approval and quota

- AOAI access is gated. If this is a new subscription, request access via the **Limited Access** form first.
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

If the customer has shared Fabric capacity, confirm there is headroom; ingestion pipelines can spike capacity usage.

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

---

## 7 — Azure Document Intelligence

### Required

- **Document Intelligence resource** in the target subscription + region (same region as AOAI / AI Search ideally)
- **Standard pricing tier** (Free tier is limited to 500 pages/month — fine for demo, not for production)

The pattern uses only the `prebuilt-read` model — no custom training, no Document Intelligence Studio work required.

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

Used as fallback for any credentials that cannot use managed identity (today: Copilot Studio's AI Search admin/query key).

---

## 10 — RBAC role assignments (cheat sheet)

These are the role assignments you will make during deployment. List them out in advance so you can request them in batch if Owner approvals are required.

| Principal | Role | Scope | Why |
|---|---|---|---|
| Fabric workspace identity (or service principal) | **Storage Blob Data Contributor** | Storage account | Write raw + chunk files |
| Fabric workspace identity | **Cognitive Services User** | Document Intelligence resource | Call OCR |
| Fabric workspace identity | **Cognitive Services OpenAI User** | AOAI resource | (Optional) direct AOAI calls; skip if pipeline doesn't call AOAI directly |
| AI Search service managed identity | **Storage Blob Data Reader** | Storage account (or `chunks/` container) | Indexer pulls chunk JSON |
| AI Search service managed identity | **Cognitive Services OpenAI User** | AOAI resource | **Integrated vectorizer auth** — critical |
| Building user | **Key Vault Secrets Officer** | Key Vault | Manage secrets during build |
| Building user | **Search Service Contributor** | AI Search | Create + manage indexes |
| Building user | **Cognitive Services Contributor** | AOAI + Document Intelligence | Deploy models, view keys |

---

## 11 — Regional alignment

Co-locate these in the same Azure region wherever possible:

- AOAI
- AI Search
- Document Intelligence
- Blob Storage
- Key Vault

Fabric capacity region should match unless cross-region data egress is acceptable.

Copilot Studio environment region is independent and can differ; choose based on customer data-residency policy.

**Cross-region egress** is the most common silent cost driver in this pattern — pay attention to it during region selection.

---

## 12 — Naming convention (reference)

A consistent naming convention makes the build navigable and replicable. Suggested scaffold (adjust to your customer's standards):

```
Resource group:   rg-<workload>-<env>-<region>           e.g.  rg-rag-demo-eus
AI Search:        srch-<workload>-<env>-<region>         e.g.  srch-rag-demo-eus
AOAI:             aoai-<workload>-<env>-<region>         e.g.  aoai-rag-demo-eus
Doc Intelligence: di-<workload>-<env>-<region>           e.g.  di-rag-demo-eus
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
| AOAI | TPM per deployment | 10K each (embedding + chat) | Azure portal → AOAI resource → Quotas |
| AOAI | Number of deployments | 2 (embedding + chat) | Same |
| AI Search | Services per subscription | 1 | Azure portal → subscription → Usage + quotas → Search |
| AI Search | Semantic ranker queries / month | Free quota or paid | AI Search service → Semantic ranker blade |
| Document Intelligence | Pages per month | Standard tier: ≥ 1M | DI resource → Quotas |
| Storage | Account count + capacity | 1 account, ≤ 100 GB for demo | Subscription quotas |
| Fabric | Capacity headroom | Demo: F4–F8 | Fabric Admin Portal |

---

## 14 — Rough cost estimate

Indicative monthly costs for a **demo / pilot** scale (single region, ~10K docs corpus, low query volume). Actuals vary by region; pull current pricing for your scenario.

| Component | Demo cost / month (USD) | Notes |
|---|---|---|
| AI Search Standard S1 | ~$250 | One replica, one partition |
| AOAI embedding (text-embedding-3-large) | ~$10–$50 | One-time bulk embed + low ongoing |
| AOAI chat (gpt-4o) | ~$50–$200 | Scales with query volume |
| Document Intelligence (prebuilt-read) | ~$15–$30 | $1.50 / 1K pages |
| Blob Storage (Hot, ~50 GB) | ~$2 | |
| Key Vault | ~$1 | |
| Fabric F4 capacity | ~$525 (24/7) or pause when idle | Major variable cost; pause aggressively for demos |
| Copilot Studio license | Per-user | Usually already in customer M365 footprint |
| **Total (demo, capacity paused off-hours)** | **~$400–$600 / month** | |

**Production** scale (~100K–1M docs, sustained QPS) typically lands **$2K–$10K / month** range with the largest variable being Fabric capacity sizing.

---

## 15 — Pre-flight checklist

Confirm all of these before moving to [03-deployment.md](./03-deployment.md):

- [ ] Azure subscription chosen, Contributor + User Access Administrator confirmed
- [ ] Target region(s) chosen with all 5 Azure services available
- [ ] AOAI access approved + quota assigned for embedding + chat models
- [ ] AI Search Standard tier budget approved
- [ ] Fabric capacity allocated to a workspace
- [ ] Copilot Studio license assigned to the builder
- [ ] Channel publishing pre-approvals initiated (Teams + M365 Copilot)
- [ ] Naming convention agreed
- [ ] Customer document source identified + access path (SharePoint shortcut, file share, etc.) planned

Once all boxes are checked → proceed to [03-deployment.md](./03-deployment.md).

---

*Last updated: 2026-05-21*

# 06 — Troubleshooting

Common failure modes and fixes for the RAG knowledge-base pattern. Organized by **where the symptom appears** so you can navigate quickly during a live incident.

> **Diagnosis flow:** start from the symptom layer (where the user sees the problem). The fix is usually one layer down. If a symptom appears at multiple layers, address the deepest layer first.

---

## Quick triage table

| Symptom | Most likely root cause | Section |
|---|---|---|
| Copilot Studio answers with "I don't have any information" | Knowledge source not bound, or index is empty | [§5](#5--copilot-studio) |
| Copilot Studio cites generic / wrong source | Hybrid+semantic not enabled in knowledge source | [§5.2](#52-citations-look-wrong-or-generic) |
| Index has 0 documents | Indexer failed, or chunks not landing in Blob | [§4](#4--ai-search-index--indexer) |
| Indexer status = `transientFailure` repeatedly | Integrated vectorizer auth failure (Foundry role) | [§4.1](#41-vectorizer-auth-failure) |
| `403 Forbidden` from indexer reading Blob | Search MI missing Storage Blob Data Reader | [§4.2](#42-indexer-cannot-read-blob) |
| Pipeline activity fails on OCR call | DI auth or wrong endpoint / API version | [§3.1](#31-document-intelligence-call-fails) |
| Pipeline chunk activity fails | Notebook auth or dependency missing | [§3.2](#32-chunking-notebook-fails) |
| Control table not updating | Notebook → Lakehouse permission issue | [§3.3](#33-control-table-stuck) |
| OneLake shortcut shows no files | Shortcut permissions or refresh lag | [§2](#2--onelake--source-attachment) |
| Cost spike | Fabric capacity left running, Foundry quota burned, indexer over-scheduled | [§6](#6--cost-and-quota) |

---

## 1 — Foundation

### 1.1 RBAC propagation lag

**Symptom.** You assigned a role; it shows in Azure portal IAM; but the consuming service still gets `403 Forbidden`.

**Cause.** Azure role assignments take up to **15 minutes** to propagate to consuming services, especially across different resource types (Search → Foundry, Search → Storage).

**Fix.** Wait 5–15 min and retry. If still failing after 15 min:

- Confirm the role assignment is on the correct **principal type** (System Assigned Managed Identity, User Assigned MI, Service Principal, or User)
- Confirm the role is at the right **scope** (resource vs resource group vs subscription)
- Re-issue the assignment (sometimes Azure replicates faster on a re-write)

### 1.2 Key Vault access denied during build

**Symptom.** You can see the vault but cannot list / get secrets.

**Cause.** RBAC-authorization mode requires a **role**, not an access policy.

**Fix.** Assign yourself **Key Vault Secrets Officer** (or **Key Vault Administrator**) on the vault. The mere ability to navigate to the vault in the portal does not imply data-plane access.

---

## 2 — OneLake / source attachment

### 2.1 Shortcut shows no files

**Symptom.** The OneLake shortcut to SharePoint / ADLS / Blob shows no contents in the Lakehouse Files view.

**Common causes & fixes:**

- **Identity mismatch.** The shortcut authenticates as the user who created it. If you created the shortcut and a service identity needs to read it: re-create the shortcut signed in as the service identity, OR re-create using a configured connection / credential.
- **Permission gap.** The shortcut's identity lacks read on the source. Add the identity to the source ACL.
- **Indexing lag.** OneLake shortcut content listing can lag minutes. Refresh the Lakehouse explorer.

### 2.2 Files visible but pipeline can't read them

**Symptom.** You can list files in the Lakehouse explorer but `spark.read.format("binaryFile").load(...)` returns 0 rows.

**Common causes & fixes:**

- The shortcut points at a folder; you're loading the folder itself rather than its contents. Add `/*` or recursive option (`option("recursiveFileLookup", "true")`).
- Path syntax. OneLake paths use `Files/` and `Tables/` prefixes; confirm the path matches the explorer view.

---

## 3 — Fabric Data Pipeline

### 3.1 Document Intelligence call fails

**Symptom.** Web activity calling Document Intelligence returns 401 / 403 / 404 / 500.

| Status | Common cause | Fix |
|---|---|---|
| 401 | Missing or wrong subscription key | Re-pull from Key Vault; confirm correct vault and secret name |
| 403 | Key valid but resource access denied | Confirm DI resource is in the same tenant; check firewall rules on DI resource |
| 404 | Wrong URL or model name | Confirm endpoint includes `/documentintelligence/...` and uses `prebuilt-read` |
| 500 | DI service-side error | Retry; if persistent, check Azure status page; verify file is not corrupt and is < DI per-call size limit |

### 3.2 Chunking notebook fails

**Symptom.** The chunking notebook errors out, often with `ModuleNotFoundError: tiktoken` or `azure.storage.blob`.

**Cause.** Fabric notebook environments don't have these packages preinstalled.

**Fix.** Add a pip install cell at the top of the notebook:

```python
%pip install tiktoken azure-storage-blob azure-identity
```

For production: pin versions and consider a custom Fabric environment with these packages baked in.

### 3.3 Control table stuck

**Symptom.** Pipeline runs without errors, but `control_table_files` rows never update from `pending` to `succeeded`.

**Common causes:**

- The "after" update notebook is not actually running (check pipeline activity status, not just notebook output)
- `MERGE INTO` is hitting a schema mismatch (Delta requires exact field types)
- Lakehouse SQL endpoint cached results — query via the Lakehouse explorer to see actual state

**Fix.** Run the update notebook standalone with hardcoded values to confirm it works. Add explicit `print` of resulting row to the notebook output for observability.

### 3.4 Pipeline runs duplicate files

**Symptom.** Each pipeline run re-processes files it has already processed.

**Cause.** `file_id` hash is not stable — typically because `source_modified_ts` is included but the upstream source updates it on every read (some storage tiers do this).

**Fix.** Switch the hash input to `(source_path, byte_size, content_md5)` if available. As a last resort, hash the file content (slower).

---

## 4 — AI Search index / indexer

### 4.1 Vectorizer auth failure

**Symptom.** Indexer status shows `lastResult.errorMessage` referencing OpenAI 401 / 403 from the Foundry endpoint, or "managed identity not authorized to invoke embedding deployment."

**Cause.** AI Search service's managed identity does not have **Cognitive Services OpenAI User** role on the Foundry resource hosting the embedding deployment.

**Fix.**

```bash
SEARCH_OBJID=<AI Search system-assigned MI object ID>
AIF_RES_ID=$(az cognitiveservices account show --name <foundry-resource> -g <rg> --query id -o tsv)

az role assignment create \
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope $AIF_RES_ID
```

Wait up to 15 minutes for propagation, then re-run the indexer.

**Also check:** the vectorizer definition's `azureOpenAIParameters.authIdentity` is set correctly. `null` = system-assigned managed identity. If you used a user-assigned MI, you must set the identity ID explicitly.

### 4.2 Indexer cannot read Blob

**Symptom.** Indexer status: "The remote server returned an error: (403) Forbidden" while reading the data source.

**Cause.** AI Search MI lacks **Storage Blob Data Reader** on the storage account (or chunks container).

**Fix.**

```bash
ST_RES_ID=$(az storage account show --name <st> -g <rg> --query id -o tsv)

az role assignment create \
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope $ST_RES_ID
```

**Also check:** the data source connection string uses the `ResourceId=...;` form (managed-identity) and not a key-based connection string. The latter can silently fail to authenticate when networking restrictions apply.

### 4.3 Indexer succeeds but documents have no vectors

**Symptom.** Indexer status = `success`, document count = expected, but `content_vector` field is empty or missing.

**Common causes:**

- Vectorizer not assigned to the field's `vectorSearchProfile` — confirm the index schema
- Embedding model dimensionality mismatch — `content_vector.dimensions` in the schema must equal the model output dim (3072 for `text-embedding-3-large`, 1536 for `-3-small`)
- Vectorizer name in `vectorSearch.profiles[].vectorizer` doesn't match `vectorSearch.vectorizers[].name`

**Fix.** Update the index schema. **Note:** changing a vector field's dimensionality requires **dropping and recreating the index** (cannot be altered in place). Plan re-indexing time.

### 4.4 Semantic ranker not returning captions

**Symptom.** Queries with `"queryType": "semantic"` return results but `@search.captions` is empty / null.

**Common causes:**

- Tier mismatch — semantic ranker not available on Basic/Free
- `semanticConfiguration` not specified in the query
- `captions` not requested in the query (must include `"captions": "extractive"`)
- Semantic ranker monthly quota exhausted (paid tier kicks in)

**Fix.** Check tier, request body, and quota:

```bash
# Check tier
az search service show --name <srch> -g <rg> --query "sku.name"
# Expected: "standard" or higher

# Check semantic ranker queries-used in the portal (Semantic ranker blade)
```

### 4.5 Indexer schedule not firing

**Symptom.** Indexer has a schedule but no runs are happening.

**Cause.** Indexer is **disabled**, or scheduling is set on a paused service.

**Fix.**

```bash
GET https://<srch>.search.windows.net/indexers/<name>?api-version=2024-07-01
# Confirm "disabled": false
```

Manually run once to confirm health, then check scheduling settings.

---

## 5 — Copilot Studio

### 5.1 Agent answers "I don't have any information"

**Common causes:**

1. Knowledge source not bound (check **Knowledge** tab)
2. Knowledge source bound but **semantic search not enabled** in source config
3. **Generative AI** not enabled in agent settings
4. Authentication misconfigured (admin key wrong, or Entra auth missing user permission to search)
5. Index actually has zero documents

**Diagnosis steps:**

1. In Copilot Studio **Test pane**: ask a question whose answer is definitely in the corpus
2. Check the agent's **Activity** trace — does it call the knowledge source?
3. If it calls but returns nothing → AI Search query issue ([§4](#4--ai-search-index--indexer))
4. If it doesn't call → knowledge source not enabled for this topic / fallback

### 5.2 Citations look wrong or generic

**Symptom.** Answer is correct but the citation points to "Source 1" rather than a meaningful document name.

**Cause.** The **Title field** in the knowledge source config isn't a friendly field, or the field isn't `retrievable` in the index schema.

**Fix.**

- Add a `title` field to the index schema (or repurpose `doc_id`) that holds a friendly document name
- Re-index
- In Copilot Studio knowledge source: set **Title field** = the friendly field

### 5.3 Citation link doesn't open the source

**Symptom.** Citation appears but clicking it does nothing or 404s.

**Common causes:**

- `source_uri` field not set on the index schema or not retrievable
- The Blob URI is private and the user lacks access
- The Copilot Studio knowledge source **URL field** is not configured

**Fix.**

- Confirm `source_uri` is `retrievable: true` in the index
- In Copilot Studio knowledge source config: set **URL field** = `source_uri`
- For private Blob: either grant users Blob read on the storage account, or pre-process during pipeline to write a SAS-signed URL into a separate `source_url_signed` field (with expiry)

### 5.4 Agent ignores knowledge source for some questions

**Symptom.** Some questions invoke the knowledge source; others get a stock LLM answer without grounding.

**Cause.** Copilot Studio routes queries through topics. If a topic matches before generative answers fires, the topic wins.

**Fix.** Review the topic list, remove or narrow the trigger phrases of topics that should not intercept knowledge questions. As a stopgap: configure **Generative AI** as the primary handler and topics as escalations.

### 5.5 Cannot publish to Teams

**Cause.** Power Platform admin has not approved the channel deployment for this environment.

**Fix.** Submit the channel-publishing approval request and wait for admin approval. There is no self-service workaround.

### 5.6 Cannot publish to M365 Copilot

**Cause.** Tenant M365 admin has not enabled third-party agents in M365 Copilot.

**Fix.** Same as above — admin must enable in M365 admin center.

---

## 6 — Cost and quota

### 6.1 Fabric capacity cost spike

**Symptom.** Monthly Fabric bill is significantly above estimate.

**Common causes:**

- Capacity left running 24/7 during demo phase (largest single contributor)
- Indexer running every minute (multiple indexer runs / hour)
- Notebook attached to a session that never released

**Fixes:**

- **Pause** the Fabric capacity outside of demo / dev hours
- Set indexer schedule to a sane interval (every 5–15 min for demos; every 30+ min for production batch)
- Always stop sessions after use
- Set a **budget alert** in Azure Cost Management on the resource group + a separate one on the Fabric capacity

### 6.2 Foundry / OpenAI quota exhausted

**Symptom.** Indexer / queries fail intermittently with 429 from the Foundry OpenAI endpoint.

**Cause.** TPM quota on the embedding or chat OpenAI deployment hit ceiling.

**Fixes:**

- Increase TPM on the deployment (Azure portal → Foundry resource → Quotas; OpenAI deployments use the AOAI quota plane)
- For indexer-side: schedule the indexer less aggressively
- For query-side: add Copilot Studio rate limiting; or move to higher TPM tier

### 6.3 Semantic ranker quota exhausted

**Symptom.** Queries with `queryType: "semantic"` start returning results without semantic re-ranker scores or captions.

**Cause.** Monthly free quota hit (currently ~1K queries / month at time of writing).

**Fix.** Either accept the metered cost (~$1 / 1K), or fall back to hybrid-only for low-priority queries. Configure separate Copilot Studio knowledge sources if you want to control which queries get semantic ranking.

---

## 7 — Networking

(Only relevant for production deployments with private endpoints.)

### 7.1 Indexer cannot reach Foundry resource through private endpoint

**Cause.** AI Search service does not have a **shared private link** to the Foundry resource.

**Fix.** In AI Search → **Settings → Networking → Shared private access → Add**: target the Foundry resource. Approve the connection on the Foundry side.

### 7.2 Indexer cannot reach Blob through private endpoint

**Same pattern**: shared private link from AI Search → Blob, approved on the Blob side.

### 7.3 Fabric cannot reach Blob through private endpoint

**Cause.** Fabric workspace not in a managed VNet, or Blob firewall rules don't include Fabric egress IPs.

**Fix.** Configure Fabric workspace with managed VNet (preview / GA depending on tenant) OR add Fabric public egress IP ranges to Blob firewall (less secure; documented in Microsoft Learn).

---

## 8 — Diagnostic toolbox

When you can't figure out where the failure is:

### 8.1 Check logs in this order

1. **Fabric Pipeline activity output** — shows raw error from each step
2. **AI Search indexer status** — `GET .../indexers/<name>/status?api-version=2024-07-01`
3. **Foundry / OpenAI metrics** — Azure portal → Foundry resource → Metrics blade → TPM utilization, throttling
4. **AI Search metrics** — search latency, throttling, error rate
5. **Copilot Studio Test pane activity trace** — shows which knowledge source was called

### 8.2 Useful queries

**Index documents with empty vectors:**

```json
POST .../indexes/<name>/docs/search?api-version=2024-07-01
{
  "search": "*",
  "filter": "content_vector eq null",
  "select": "id,doc_id",
  "$count": true
}
```

**Indexer execution history:**

```bash
GET .../indexers/<name>/status?api-version=2024-07-01
```

**Recent failed control-table rows:**

```sql
SELECT file_id, ocr_status, chunk_status, index_status, last_error, ingest_ts
FROM control_table_files
WHERE last_error IS NOT NULL
ORDER BY ingest_ts DESC
LIMIT 20
```

---

## 9 — When to escalate

Escalate to support / Microsoft if, after working through this guide:

| Issue | Escalate to |
|---|---|
| Persistent indexer 5xx errors | Azure support (AI Search) |
| Foundry / OpenAI capacity / region constraint blocking deployment | Foundry / Azure OpenAI access team |
| Fabric Data Pipeline activity bug | Fabric support |
| Copilot Studio publishing approval stuck > 5 business days | Power Platform admin → escalation |
| Semantic ranker returning incorrect captions for a specific query class | Microsoft Learn Q&A first; AI Search support if reproducible |

For Microsoft sellers: open a fast-path support case via your account team if the issue is blocking a customer demo or production deployment.

---

*Last updated: 2026-05-21*

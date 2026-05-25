# 03 — Azure platform layer — Manual deployment (portal + CLI)

Step-by-step manual build of the **Azure platform layer** of the RAG knowledge-base pattern. Assumes all of [02-prerequisites.md](./02-prerequisites.md) is complete.

> **What this document is.** A no-IaC, click-through walkthrough that provisions the **Azure resources** in the pattern (RG, Key Vault, Storage, Document Intelligence, Azure AI Foundry + 2 model deployments, AI Search, RBAC, and the AI Search index / data source / indexer). The same Azure end-state is reproducible with [Bicep](./04-deployment-automated.md) — use this manual path when you want to learn the components hands-on or for one-off demo labs; use Bicep for repeatable / CI deployments.

> **What this document is NOT.** It does **not** cover the Fabric ingestion pipeline or the Copilot Studio agent. Both of those layers are always manual (no IaC surface exists for them today) and have their own dedicated runbooks:
>
> - **Fabric** (workspace, identity, Lakehouse, OneLake shortcut, control table, ingest pipeline) → [03b-fabric-setup.md](./03b-fabric-setup.md)
> - **Copilot Studio** (agent, AI Search knowledge source binding, channel publishing) → [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md)
>
> The full end-to-end build sequence — Azure (this doc or Bicep) → Fabric → Copilot Studio — is orchestrated by [00-reproduce-this-demo.md](./00-reproduce-this-demo.md).

> **Build order matters.** Phases are sequential because each depends on artifacts from the prior phase. Within a phase, steps are also sequential unless explicitly marked parallel-safe.

---

## Where this fits in the overall build

| Layer | Owner | Doc | Automatable? |
|---|---|---|---|
| **Azure platform** (RG, KV, Storage, DI, Foundry, AI Search, RBAC, index/indexer) | This doc | **03 (this doc, manual)** or [04 (Bicep)](./04-deployment-automated.md) | Yes — via Bicep + post-deploy Python script |
| **Fabric workspace + ingest pipeline** | Fabric tenant admin + builder | [03b-fabric-setup.md](./03b-fabric-setup.md) | No — Fabric workspaces / Lakehouses / pipelines have no Bicep / ARM provider today |
| **Copilot Studio agent + publishing** | Power Platform admin + builder | [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md) | No — Power Platform, not Azure |

## Phase overview (this doc)

| Phase | What you build | ~Time | Validation at end |
|---|---|---|---|
| **1** | **Azure foundation:** RG + Key Vault + Blob + Document Intelligence + Azure AI Foundry + 2 model deployments + AI Search + RBAC | 60–90 min | All Azure resources deployed; identities + RBAC set |
| **4** | **AI Search index:** schema, integrated vectorizer, hybrid + semantic configuration; indexer pointed at Blob `chunks/` | 45–60 min | Indexer run succeeds; sample query returns chunks with semantic captions |

In between Phase 1 and Phase 4 you switch to **[03b-fabric-setup.md](./03b-fabric-setup.md)** to build the Fabric ingest pipeline (which produces the chunk JSON files in Blob `chunks/` that the Phase 4 indexer consumes). After Phase 4 validates, switch to **[03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md)** to build the agent on top of the populated index.

> **Why phases 2, 3, and 5 are not in this document.** They are the Fabric layer (§03b) and Copilot Studio layer (§03c) respectively. Phase numbering for the Azure-side phases is preserved across versions so existing cross-references (testing, troubleshooting, orchestrator) continue to resolve.

**Total Azure-only manual build: roughly 2–3 hours of hands-on time.** Full demo (Azure + Fabric + Copilot Studio): **4–6 hours** — see [00-reproduce-this-demo.md](./00-reproduce-this-demo.md) for the orchestrated time budget.

---

## Phase 1 — Foundation

### 1.1 Create the resource group

```bash
LOC=eastus
RG=rg-rag-demo-eus

az group create --name $RG --location $LOC
```

### 1.2 Create Key Vault

```bash
KV=kv-rag-demo-eus

az keyvault create \
  --name $KV --resource-group $RG --location $LOC \
  --enable-rbac-authorization true
```

Grant yourself **Key Vault Secrets Officer** on the vault for the duration of the build.

### 1.3 Create Storage account + containers

```bash
ST=stragdemoeus

az storage account create \
  --name $ST --resource-group $RG --location $LOC \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false

az storage container create --account-name $ST --name raw --auth-mode login
az storage container create --account-name $ST --name chunks --auth-mode login
```

> **`--allow-shared-key-access false`** disables the storage account access keys. Every reader and writer (AI Search indexer, Document Intelligence, Fabric pipeline, you) must authenticate with Entra ID via a managed identity / service principal / signed-in user. The container-creation commands above use `--auth-mode login` so they go through your Azure CLI identity rather than account keys.

### 1.4 Create Document Intelligence

In the Azure portal:

1. **Create a resource → Document Intelligence**
2. Resource group: `rg-rag-demo-eus`
3. Region: same as the rest
4. Pricing tier: **Standard S0** (not Free — free is page-limited)
5. Create
6. After deployment: **Identity → System assigned → Status: On → Save**. Note the **Object (principal) ID** — you grant this Blob Data Reader in step 1.7 so DI can fetch private blobs via `urlSource`.
7. **Networking / Resource management → Disable local authentication**. Or via CLI:
   ```bash
   az cognitiveservices account update \
     --name di-rag-demo-eus --resource-group $RG \
     --custom-domain di-rag-demo-eus \
     --properties '{"disableLocalAuth": true}'
   ```

No keys are stored anywhere. Clients call DI with `Authorization: Bearer <entra-token>` (token resource: `https://cognitiveservices.azure.com/`) and a role assignment of **Cognitive Services User** on this resource.

### 1.5 Create Azure AI Foundry resource + OpenAI deployments

> **Why a Foundry resource, not a standalone Azure OpenAI resource?** The Azure AI Foundry resource (kind `AIServices`) is the strategic Microsoft model-gateway resource. It hosts OpenAI models (and the broader Foundry catalog: Cohere, Llama, Phi, Mistral, …) under a single resource and exposes an OpenAI-compatible endpoint at `https://<resource>.openai.azure.com/` — so the AI Search integrated `azureOpenAI` vectorizer works against it unchanged. This pattern uses Foundry's model-gateway capability only; Foundry's agent runtime (Agent Service / Hub / Projects) is **not** used here — Copilot Studio fills the agent role. Foundry agent runtime is the right addition for engagements that need multi-agent routing, custom tool calling, or query triage beyond knowledge-base Q&A.

In the Azure portal:

1. **Create a resource → Azure AI Foundry** (look for the "Azure AI Foundry" tile; under the hood this provisions a Cognitive Services resource of kind `AIServices`)
2. Same resource group, region (confirm OpenAI model availability for the region)
3. Pricing tier: **Standard S0**
4. After deployment: open **Azure AI Foundry portal** (foundry.azure.com) → select the resource → **Models + endpoints → Deploy a model**:
   - Deploy `text-embedding-3-large` → name it `embedding`
   - Deploy `gpt-4o` → name it `chat`
   - For both: set capacity to 10K TPM for demo
   - (Optional) browse the Foundry catalog for non-OpenAI models if you plan to extend later; this pattern only requires the two OpenAI deployments above
5. Confirm the OpenAI-compatible endpoint: **Endpoints** view shows `https://aif-rag-demo-eus.openai.azure.com/` — that's the value the AI Search vectorizer will use
6. **Identity → System assigned → Status: On** (not required by this pattern's flows but enables future scenarios)
7. **Disable local authentication** — same CLI pattern as 1.4:
   ```bash
   az cognitiveservices account update \
     --name aif-rag-demo-eus --resource-group $RG \
     --custom-domain aif-rag-demo-eus \
     --properties '{"disableLocalAuth": true}'
   ```

No keys are stored anywhere. The AI Search integrated vectorizer authenticates via its system-assigned managed identity (granted **Cognitive Services User** on this resource in step 1.7).

### 1.6 Create AI Search

In the Azure portal:

1. **Create a resource → Azure AI Search**
2. Same RG, region
3. **Pricing tier: Standard (S1)** — semantic ranker is NOT available below this
4. Replicas: 1, Partitions: 1
5. **Networking** — leave Public network access enabled for demo; lock down with private endpoints for production
6. **Identity → System assigned → Status: On → Save** (note the object ID — needed in step 1.7)
7. **Keys** — set **API access control** to **Role-based access control** and disable local auth:
   ```bash
   az search service update \
     --name srch-rag-demo-eus --resource-group $RG \
     --auth-options aadOrApiKey \
     --aad-auth-failure-mode http401WithBearerChallenge \
     --disable-local-auth true
   ```
   (The `aadOrApiKey` option still controls the bearer-challenge configuration; `--disable-local-auth true` rejects all API keys regardless.)
8. **Semantic ranker**: confirm enabled (Standard tier includes a free quota; Free plan is acceptable for demo)

No admin or query keys are stored anywhere. All callers (your post-deploy work, Copilot Studio, app code) authenticate with Entra bearer tokens (resource: `https://search.azure.com/`).

### 1.7 RBAC wiring

With API keys disabled across Foundry, DI, AI Search, and Storage, **every** data-plane interaction depends on a role assignment. Skip any of these and the corresponding service call will return 401 or 403.

```bash
# Identities
SEARCH_OBJID=<AI Search system-assigned MI object ID from step 1.6>
DI_OBJID=<Document Intelligence system-assigned MI object ID from step 1.4>
ME_OBJID=$(az ad signed-in-user show --query id -o tsv)

# Resource IDs
AIF_RES_ID=$(az cognitiveservices account show --name aif-rag-demo-eus -g $RG --query id -o tsv)
DI_RES_ID=$(az cognitiveservices account show --name di-rag-demo-eus -g $RG --query id -o tsv)
SRCH_RES_ID=$(az search service show --name srch-rag-demo-eus -g $RG --query id -o tsv)
ST_RES_ID=$(az storage account show --name $ST -g $RG --query id -o tsv)

# 1. AI Search → Foundry (integrated vectorizer calls the embedding deployment)
az role assignment create \
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope $AIF_RES_ID

# 2. AI Search → Blob (indexer pulls chunk JSON from chunks/)
az role assignment create \
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope $ST_RES_ID

# 3. Document Intelligence → Blob (urlSource fetches raw/<file> via DI's own MI;
#    required because shared-key access on Storage is disabled and you can't pass a SAS)
az role assignment create \
  --assignee-object-id $DI_OBJID --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope $ST_RES_ID

# 4. You → AI Search (lets you create + manage the index, datasource, indexer via bearer
#    token; lets you run sample queries during build/test)
az role assignment create \
  --assignee-object-id $ME_OBJID --assignee-principal-type User \
  --role "Search Service Contributor" \
  --scope $SRCH_RES_ID
az role assignment create \
  --assignee-object-id $ME_OBJID --assignee-principal-type User \
  --role "Search Index Data Contributor" \
  --scope $SRCH_RES_ID

# 5. You → Storage (lets you upload / inspect blobs through Azure CLI / portal)
az role assignment create \
  --assignee-object-id $ME_OBJID --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope $ST_RES_ID
```

> **Propagation:** Azure role assignments take up to **15 minutes** to be honored, especially cross-resource-type assignments (Search MI → Foundry, Search MI → Storage). If subsequent steps return 401 or 403, wait and retry before debugging further.

Fabric workspace identity → Blob (Data Contributor) and Fabric workspace identity → Document Intelligence (Cognitive Services User) are configured later from the Fabric side once the workspace identity exists, in [03b-fabric-setup.md § Phase F2.1](./03b-fabric-setup.md#f21-grant-the-workspace-identity-the-required-roles). Skip them here.

### Phase 1 validation

- [ ] All 6 Azure resources exist in the same RG and region
- [ ] Foundry, Document Intelligence, and AI Search show **Local authentication: Disabled**
- [ ] Storage account shows **Allow storage account key access: Disabled**
- [ ] AI Search system-assigned MI has both role assignments visible in IAM (Cognitive Services User on Foundry, Storage Blob Data Reader on Storage)
- [ ] Document Intelligence system-assigned MI has **Storage Blob Data Reader** on the storage account
- [ ] You have **Search Service Contributor** + **Search Index Data Contributor** on the AI Search service
- [ ] Foundry resource has two deployments: `embedding` (text-embedding-3-large) and `chat` (gpt-4o)
- [ ] Key Vault exists and you have **Key Vault Secrets Officer** on it (used later if any secret-based fallback becomes necessary; this pattern stores no API keys in it)

---

## Phases 2 and 3 — Fabric setup

The Fabric workspace, Lakehouse, OneLake shortcut, control Delta table, connections (Key Vault + Blob), pipeline notebooks, and the Data Pipeline itself are all manual and **identical for both the manual and the automated Azure path**.

👉 **Follow [03b-fabric-setup.md](./03b-fabric-setup.md) end-to-end now**, then come back here to continue with [Phase 4 — AI Search index](#phase-4--ai-search-index). The 10 Fabric phases (F0–F10) cover tenant prerequisites, workspace + identity, Lakehouse, OneLake shortcut, control table, connections, pipeline notebooks, the `pl_ingest_docs` Data Pipeline, end-to-end validation, and pipeline scheduling.

**Do not proceed to Phase 4 below until 03b's validation checklist is fully checked** — Phase 4 requires chunk JSON files to be landing in Blob `chunks/` for the indexer to be testable end-to-end.

---

## Phase 4 — AI Search index

> **Auth model.** Admin keys are disabled on the AI Search service (from Phase 1.6). Every REST call below must include an Entra bearer token:
>
> ```bash
> TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
> # then add the header to every PUT/POST/GET:
> #   -H "Authorization: Bearer $TOKEN"
> ```
>
> The samples below use a single `Authorization: Bearer <token>` header instead of `api-key:`. Your signed-in identity needs **Search Service Contributor** (for index/datasource/indexer PUT) + **Search Index Data Contributor** (for `/docs/search`), both granted in Phase 1.7.

### 4.1 Create the index

In the AI Search portal → **Indexes → + Add index** (or use the REST API for full schema control).

The REST API is easier for getting the integrated vectorizer right. Sample payload:

```http
PUT https://srch-rag-demo-eus.search.windows.net/indexes/idx-rag-documents?api-version=2024-07-01
Content-Type: application/json
Authorization: Bearer <token from `az account get-access-token --resource https://search.azure.com`>

{
  "name": "idx-rag-documents",
  "fields": [
    { "name": "id",            "type": "Edm.String", "key": true, "filterable": true },
    { "name": "doc_id",        "type": "Edm.String", "filterable": true, "facetable": true },
    { "name": "chunk_id",      "type": "Edm.Int32",  "retrievable": true },
    { "name": "content",       "type": "Edm.String", "searchable": true, "analyzer": "en.microsoft" },
    { "name": "content_vector","type": "Collection(Edm.Single)", "searchable": true,
      "dimensions": 3072,
      "vectorSearchProfile": "default-vector-profile" },
    { "name": "doc_type",      "type": "Edm.String", "filterable": true, "facetable": true },
    { "name": "source_uri",    "type": "Edm.String", "retrievable": true },
    { "name": "page_start",    "type": "Edm.Int32",  "retrievable": true },
    { "name": "page_end",      "type": "Edm.Int32",  "retrievable": true },
    { "name": "ingest_ts",     "type": "Edm.DateTimeOffset", "filterable": true, "sortable": true },
    { "name": "metadata",      "type": "Edm.String", "retrievable": true }
  ],
  "vectorSearch": {
    "algorithms": [
      { "name": "hnsw-default", "kind": "hnsw",
        "hnswParameters": { "m": 4, "efConstruction": 400, "efSearch": 500, "metric": "cosine" } }
    ],
    "vectorizers": [
      {
        "name": "aif-vectorizer",
        "kind": "azureOpenAI",
        "azureOpenAIParameters": {
          "resourceUri": "https://aif-rag-demo-eus.openai.azure.com",
          "deploymentId": "embedding",
          "modelName": "text-embedding-3-large",
          "authIdentity": null
        }
      }
    ],
    "profiles": [
      { "name": "default-vector-profile", "algorithm": "hnsw-default", "vectorizer": "aif-vectorizer" }
    ]
  },
  "semantic": {
    "defaultConfiguration": "semantic-default",
    "configurations": [
      {
        "name": "semantic-default",
        "prioritizedFields": {
          "titleField":         { "fieldName": "doc_id" },
          "prioritizedContentFields": [ { "fieldName": "content" } ],
          "prioritizedKeywordsFields": [ { "fieldName": "doc_type" } ]
        }
      }
    ]
  }
}
```

> **Critical:** the `vectorizers[0].azureOpenAIParameters.authIdentity` set to `null` means **use the service's system-assigned managed identity**. The role assignment from Phase 1.7 (Cognitive Services User on the Foundry resource) is what makes this work. If you used a user-assigned identity instead, set the identity object here. The `resourceUri` uses the Foundry resource's OpenAI-compatible endpoint (`*.openai.azure.com`) — Foundry resources expose this for backwards-compatible tooling like the AI Search vectorizer.

### 4.2 Create the data source

Points the indexer at the Blob `chunks/` container.

```http
PUT https://srch-rag-demo-eus.search.windows.net/datasources/ds-chunks?api-version=2024-07-01
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "ds-chunks",
  "type": "azureblob",
  "credentials": { "connectionString": "ResourceId=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<st>;" },
  "container": { "name": "chunks" }
}
```

Using the `ResourceId=...;` connection string enables **managed-identity authentication** — the indexer authenticates to Blob with its system-assigned MI (granted Storage Blob Data Reader in Phase 1.7). No storage account key is referenced or required.

### 4.3 Create the indexer

```http
PUT https://srch-rag-demo-eus.search.windows.net/indexers/ixr-chunks?api-version=2024-07-01
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "ixr-chunks",
  "dataSourceName": "ds-chunks",
  "targetIndexName": "idx-rag-documents",
  "parameters": {
    "configuration": { "parsingMode": "json" }
  },
  "fieldMappings": [
    { "sourceFieldName": "id",         "targetFieldName": "id" },
    { "sourceFieldName": "doc_id",     "targetFieldName": "doc_id" },
    { "sourceFieldName": "chunk_id",   "targetFieldName": "chunk_id" },
    { "sourceFieldName": "content",    "targetFieldName": "content" },
    { "sourceFieldName": "doc_type",   "targetFieldName": "doc_type" },
    { "sourceFieldName": "source_uri", "targetFieldName": "source_uri" },
    { "sourceFieldName": "page_start", "targetFieldName": "page_start" },
    { "sourceFieldName": "page_end",   "targetFieldName": "page_end" },
    { "sourceFieldName": "ingest_ts",  "targetFieldName": "ingest_ts" },
    { "sourceFieldName": "metadata",   "targetFieldName": "metadata" }
  ],
  "schedule": { "interval": "PT5M" }
}
```

Note: `content_vector` is **not** in field mappings — the integrated vectorizer generates it automatically from `content` at index time.

### 4.4 Run the indexer manually

```bash
TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)

curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  "https://srch-rag-demo-eus.search.windows.net/indexers/ixr-chunks/run?api-version=2024-07-01"
```

Then watch status:

```bash
curl -H "Authorization: Bearer $TOKEN" \
  "https://srch-rag-demo-eus.search.windows.net/indexers/ixr-chunks/status?api-version=2024-07-01"
```

A successful run shows `lastResult.status = "success"` and `itemsProcessed` matching the number of chunk JSONs in Blob.

### 4.5 Smoke-test the index

Run a sample query that exercises hybrid + semantic ranker:

```http
POST https://srch-rag-demo-eus.search.windows.net/indexes/idx-rag-documents/docs/search?api-version=2024-07-01
Authorization: Bearer <token>
Content-Type: application/json

{
  "search": "<a representative question for your corpus>",
  "queryType": "semantic",
  "semanticConfiguration": "semantic-default",
  "vectorQueries": [
    {
      "kind": "text",
      "text": "<the same question>",
      "fields": "content_vector",
      "k": 50
    }
  ],
  "select": "id,doc_id,chunk_id,content,doc_type,source_uri,page_start,page_end",
  "top": 5,
  "captions": "extractive",
  "answers": "extractive"
}
```

Confirm:

- ✅ Results return without error
- ✅ Each result has a non-null `@search.rerankerScore` (proves semantic ranker fired)
- ✅ `@search.captions` contains an extractive summary

### Phase 4 validation

- [ ] Index exists with vector + semantic configurations
- [ ] Data source uses managed-identity connection string (no keys)
- [ ] Indexer last run = `success`, items processed = chunk JSON count
- [ ] Test query returns chunks with semantic re-ranker scores

---

## Next: build the Copilot Studio agent

The Azure platform layer is complete. The remaining step is to build the **Copilot Studio agent** on top of the populated AI Search index. Copilot Studio is Power Platform (not Azure) and is **always manual** regardless of which Azure deployment path you took.

👉 **Continue to [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md)** for agent creation, AI Search knowledge source binding, generative-answers configuration, and Teams + M365 Copilot channel publishing.

---

## Post-deployment checklist (Azure layer)

Once Phases 1 + 4 validate green and Fabric ([03b](./03b-fabric-setup.md)) + Copilot Studio ([03c](./03c-copilot-studio-setup.md)) are complete, proceed to [05-testing.md](./05-testing.md) to run the full test suite.

- [ ] All Phase 1 + Phase 4 validation boxes checked
- [ ] Fabric pipeline scheduled (not just on-demand) — see [03b § F10](./03b-fabric-setup.md#phase-f10--schedule-the-pipeline)
- [ ] AI Search indexer scheduled (set in [§ 4.3](#43-create-the-indexer) above with `"interval": "PT5M"`)
- [ ] Copilot Studio agent published to Teams + M365 Copilot — see [03c § C5](./03c-copilot-studio-setup.md#phase-c5--publish-to-channels)
- [ ] Cost alerts configured on the resource group
- [ ] Backup / disaster-recovery plan written (at minimum: re-runnable pipeline from `raw/` blob)
- [ ] Customer + Microsoft owners identified for ongoing operation
- [ ] **Auth posture audited:** Foundry / DI / AI Search show **Local authentication: Disabled**; Storage shows **Allow storage account key access: Disabled**
- [ ] **RBAC inventory exported:** the role assignments from Phase 1.7 documented per environment (these become the rotation surface in place of API keys)

---

*Last updated: 2026-05-24*

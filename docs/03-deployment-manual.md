# 03 — Deployment (Manual / Portal + CLI)

Step-by-step manual build of the RAG knowledge-base pattern. Assumes all of [02-prerequisites.md](./02-prerequisites.md) is complete.

> **Two deployment paths exist.** This document is the **manual / portal-driven** path — best for learning the architecture component-by-component, demo labs, and one-off builds. For repeatable / CI-driven deployments use **[04-deployment-automated.md](./04-deployment-automated.md)** instead, which provisions the same Azure resources via Bicep + a post-deploy script.
>
> The two paths produce the **same end-state**. The Fabric workspace + Copilot Studio agent steps are identical in both (they are low-code, portal-driven, and not expressible in Bicep today).

> **Build order matters.** Phases are sequential because each depends on artifacts from the prior phase. Within a phase, steps are also sequential unless explicitly marked parallel-safe.

---

## Phase overview

| Phase | What you build | ~Time | Validation at end |
|---|---|---|---|
| 1 | Foundation: RG + Key Vault + Blob + AI Search + Azure AI Foundry + Doc Intelligence + Fabric workspace + Lakehouse | 60–90 min | All resources deployed; identities + RBAC set |
| 2 | Ingestion attachment: OneLake source attached; Control Delta table created | 30–45 min | Sample docs visible in Lakehouse; control table queryable |
| 3 | Fabric Data Pipeline: OCR → chunk → write to Blob, with control-table updates | 90–180 min | Pipeline run succeeds end-to-end on a sample doc; control table reflects state |
| 4 | AI Search index: schema, integrated vectorizer, hybrid + semantic configuration; indexer pointed at Blob | 45–60 min | Indexer run succeeds; sample query returns chunks with semantic captions |
| 5 | Copilot Studio agent: knowledge source = AI Search; publish to Teams + M365 Copilot | 30–45 min | End-to-end: ask a question in Teams → get a grounded answer with citation |

**Total demo build: roughly 4–6 hours of hands-on time.**

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
  --allow-blob-public-access false

az storage container create --account-name $ST --name raw --auth-mode login
az storage container create --account-name $ST --name chunks --auth-mode login
```

### 1.4 Create Document Intelligence

In the Azure portal:

1. **Create a resource → Document Intelligence**
2. Resource group: `rg-rag-demo-eus`
3. Region: same as the rest
4. Pricing tier: **Standard S0** (not Free — free is page-limited)
5. Create
6. After deployment: copy the **endpoint** and **key 1** to Key Vault as secrets `di-endpoint` and `di-key`

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

Copy the Foundry resource's **OpenAI endpoint** and **key 1** to Key Vault as `aif-endpoint` and `aif-key`.

### 1.6 Create AI Search

In the Azure portal:

1. **Create a resource → Azure AI Search**
2. Same RG, region
3. **Pricing tier: Standard (S1)** — semantic ranker is NOT available below this
4. Replicas: 1, Partitions: 1
5. After deployment: **Settings → Identity → System-assigned managed identity → On → Save** (note the object ID)
6. **Settings → Keys → Manage admin keys**: copy the primary admin key
7. **Settings → Semantic ranker**: confirm enabled (Standard tier includes a free quota; Free plan is acceptable for demo)

Save the AI Search **endpoint** and **admin key** to Key Vault as `search-endpoint` and `search-admin-key`.

### 1.7 RBAC wiring

These are the critical role assignments. **Skip these and the integrated vectorizer will fail at index time.**

```bash
SEARCH_OBJID=<paste the AI Search system-assigned MI object ID from step 1.6>
AIF_RES_ID=$(az cognitiveservices account show --name aif-rag-demo-eus -g $RG --query id -o tsv)
ST_RES_ID=$(az storage account show --name $ST -g $RG --query id -o tsv)

# AI Search → Foundry resource (integrated vectorizer access to OpenAI deployments)
az role assignment create \
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" \
  --scope $AIF_RES_ID

# AI Search → Blob (indexer reads chunks)
az role assignment create \
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Reader" \
  --scope $ST_RES_ID
```

Fabric workspace identity → Blob (Data Contributor) is configured later in Phase 2 from the Fabric side.

### 1.8 Create Fabric workspace + Lakehouse

In the Fabric portal:

1. **Workspaces → New workspace** → name `ws-rag-demo` → assign Fabric capacity
2. Inside the workspace: **+ New → Lakehouse** → name `lh_rag_demo`
3. After creation, note the Lakehouse SQL endpoint and OneLake path

### Phase 1 validation

- [ ] All 6 Azure resources exist in the same RG and region
- [ ] Key Vault contains: `di-endpoint`, `di-key`, `aif-endpoint`, `aif-key`, `search-endpoint`, `search-admin-key`
- [ ] AI Search managed identity has both role assignments visible in Azure portal IAM
- [ ] Fabric workspace + Lakehouse exist and you have Member/Admin role

---

## Phase 2 — Ingestion attachment

### 2.1 Attach the customer's document source to OneLake

Pick one of these patterns based on the customer's source:

| Source | Pattern | How |
|---|---|---|
| SharePoint document library | **OneLake shortcut** | Lakehouse → Get data → New shortcut → Microsoft 365 → SharePoint → pick site + library |
| Azure Blob (different storage account) | **OneLake shortcut** | Lakehouse → Get data → New shortcut → Azure Data Lake Storage Gen2 |
| ADLS Gen2 / S3 / GCS | **OneLake shortcut** | Same pattern, choose the right connector |
| File share / mailbox / FTP | **Data Pipeline copy activity** (scheduled) | Set up a copy job that lands files into a `raw_landing/` folder in the Lakehouse |

For demo: use a SharePoint document library shortcut (most common low-code source).

### 2.2 Place a sample document set in the source

Drop 5–10 representative sample documents into the source. These will drive the pipeline build and testing.

> **Generic guidance:** sample diversity matters more than volume. Cover the different file types (PDF, DOCX), document lengths, and document types (policies, contracts, manuals, FAQs, etc.) the production corpus will contain.

Confirm they appear under the OneLake shortcut path in the Lakehouse explorer.

### 2.3 Create the control Delta table

In the Lakehouse, open a **Notebook** (Spark or Python) and run:

```python
from pyspark.sql.types import StructType, StructField, StringType, LongType, IntegerType, TimestampType, BooleanType

schema = StructType([
    StructField("file_id", StringType(), False),
    StructField("source_path", StringType(), True),
    StructField("source_modified_ts", TimestampType(), True),
    StructField("raw_blob_uri", StringType(), True),
    StructField("chunk_blob_prefix", StringType(), True),
    StructField("doc_type", StringType(), True),
    StructField("byte_size", LongType(), True),
    StructField("page_count", IntegerType(), True),
    StructField("ingest_run_id", StringType(), True),
    StructField("ingest_ts", TimestampType(), True),
    StructField("ocr_status", StringType(), True),
    StructField("ocr_completed_ts", TimestampType(), True),
    StructField("chunk_status", StringType(), True),
    StructField("chunk_count", IntegerType(), True),
    StructField("chunk_completed_ts", TimestampType(), True),
    StructField("index_status", StringType(), True),
    StructField("last_error", StringType(), True),
    StructField("tombstoned", BooleanType(), True),
])

empty = spark.createDataFrame([], schema)
empty.write.format("delta").mode("overwrite").saveAsTable("control_table_files")
```

Confirm the table appears in the Lakehouse Tables list and is queryable from the SQL endpoint.

### 2.4 Grant Fabric → Blob access

From the Azure portal:

1. Storage account → IAM → **Add role assignment** → **Storage Blob Data Contributor**
2. Assignee: select the **Fabric workspace identity** (search for the workspace name in the principals picker; if your tenant uses service principals instead, select that)
3. Save

Validate from a Fabric notebook by writing a test file to the Blob:

```python
# replace with your storage account name
blob_account = "stragdemoeus"
container = "raw"
# this uses Fabric workspace identity automatically
df = spark.createDataFrame([("hello", 1)], ["msg", "n"])
df.write.mode("overwrite").csv(f"abfss://{container}@{blob_account}.dfs.core.windows.net/_test/")
```

If this fails, the role assignment hasn't propagated yet — wait 5 minutes and retry.

### Phase 2 validation

- [ ] Source documents visible in the Lakehouse via shortcut or copy folder
- [ ] `control_table_files` Delta table exists and is empty
- [ ] Fabric workspace identity can read AND write to the Blob storage account from a notebook

---

## Phase 3 — Fabric Data Pipeline

This is the most complex phase. The pipeline drives the entire ingest flow: discover files → register → OCR → chunk → write → mark.

### 3.1 Pipeline design

The pipeline is one **Data Pipeline** with five sequential activities and one **Notebook** activity for chunking:

```
[1] Lookup new files (notebook or script activity)
       ↓ emits list of file_ids not yet in control_table_files
[2] ForEach file (with batched parallelism):
    [2a] Copy raw file → Blob raw/ container (Copy data activity)
    [2b] Update control table: insert row with status=pending (notebook or stored proc)
    [2c] Call Document Intelligence prebuilt-read (HTTP activity)
    [2d] Notebook: chunk extracted text → write one JSON per chunk to Blob chunks/
    [2e] Update control table: status=succeeded, chunk_count=N
[3] On error in any step: catch → update control table with last_error + status=failed
```

For low-code purity, prefer **Data Pipeline activities** for [1], [2a], [2c], [2b/e]. The chunker [2d] is the only step that needs a notebook (because chunking strategy is configurable).

### 3.2 Build activity 1 — Lookup new files

Add a **Notebook activity** (or **Script activity** if you prefer SQL). Notebook content:

```python
from pyspark.sql.functions import col

# Read OneLake source path (from shortcut or copy folder)
source_path = "Files/source_docs/"   # adjust to your shortcut location
src = spark.read.format("binaryFile").load(source_path).select("path", "modificationTime", "length")
src = src.withColumnRenamed("path", "source_path") \
         .withColumnRenamed("modificationTime", "source_modified_ts") \
         .withColumnRenamed("length", "byte_size")

# Hash file_id = md5(source_path || source_modified_ts)
from pyspark.sql.functions import md5, concat_ws
src = src.withColumn("file_id", md5(concat_ws("|", col("source_path"), col("source_modified_ts").cast("string"))))

# Anti-join against control table to find new files
ctrl = spark.table("control_table_files").select("file_id")
new_files = src.join(ctrl, on="file_id", how="left_anti")

# Persist to a temp Delta table the pipeline ForEach can read
new_files.write.format("delta").mode("overwrite").saveAsTable("_tmp_new_files")
new_files.count()
```

The pipeline's next activity (ForEach) reads `_tmp_new_files` and iterates.

### 3.3 Build activity 2a — Copy raw file to Blob

In the pipeline:

1. Add a **Copy data** activity inside a **ForEach** loop
2. Source: OneLake path = `@item().source_path`
3. Sink: Blob container `raw`, path = `@concat(item().file_id, '/', last(split(item().source_path,'/')))`
4. Authentication on the sink: **Workspace identity** (the one you granted Blob Data Contributor)

Capture the resulting blob URI into a pipeline variable for the next steps.

### 3.4 Build activity 2c — Call Document Intelligence

In the pipeline (inside the same ForEach iteration):

1. Add a **Web activity** (HTTP) to call Document Intelligence
2. URL: `@concat(<di_endpoint>, '/documentintelligence/documentModels/prebuilt-read:analyze?api-version=2024-07-31')`
3. Method: `POST`
4. Headers:
   - `Ocp-Apim-Subscription-Key`: pull from Key Vault (use the **Azure Key Vault linked service** in Fabric)
   - `Content-Type`: `application/json`
5. Body: `{ "urlSource": "<the raw blob URI from 3.3, with a SAS or use managed-identity URL>" }`
6. The async DI pattern: this returns an `operation-location` header. Add a **Until** loop that polls that URL with GET until status = `succeeded`, then captures the JSON result.

Document Intelligence returns extracted text + page structure. Pipe this to the next activity.

### 3.5 Build activity 2d — Chunking notebook

Inside the same ForEach iteration, add a **Notebook activity**. Pass in `file_id`, the DI result JSON, and the target blob path.

```python
# Parameters injected from pipeline:
# - file_id (str)
# - di_result (json)  -- full DI response
# - chunks_account (str)
# - chunks_container (str)
# - chunks_prefix (str)   e.g. f"{file_id}/"

import json
import tiktoken
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

CHUNK_TOKENS = 1000
OVERLAP_TOKENS = 200
ENCODING = tiktoken.encoding_for_model("gpt-4o")

def chunk_pages(pages, max_tok=CHUNK_TOKENS, overlap=OVERLAP_TOKENS):
    """Page-aware chunking with token-budget + overlap. Never splits mid-page."""
    chunks = []
    buf = []
    buf_tok = 0
    buf_pages = []
    for page in pages:
        page_text = page["content"]
        page_no = page["pageNumber"]
        page_tok = len(ENCODING.encode(page_text))
        if buf_tok + page_tok > max_tok and buf:
            chunks.append({"text": "\n\n".join(buf), "pages": buf_pages})
            # carry overlap forward
            buf = [buf[-1]] if overlap > 0 and buf else []
            buf_pages = [buf_pages[-1]] if overlap > 0 and buf_pages else []
            buf_tok = len(ENCODING.encode(buf[0])) if buf else 0
        buf.append(page_text)
        buf_pages.append(page_no)
        buf_tok += page_tok
    if buf:
        chunks.append({"text": "\n\n".join(buf), "pages": buf_pages})
    return chunks

pages = di_result["analyzeResult"]["pages"]
flat_pages = [{"pageNumber": p["pageNumber"],
               "content": " ".join(line["content"] for line in p.get("lines", []))}
              for p in pages]

chunks = chunk_pages(flat_pages)

cred = DefaultAzureCredential()
svc = BlobServiceClient(account_url=f"https://{chunks_account}.blob.core.windows.net", credential=cred)
container = svc.get_container_client(chunks_container)

for i, c in enumerate(chunks):
    payload = {
        "id":         f"{file_id}-{i:04d}",
        "doc_id":     file_id,
        "chunk_id":   i,
        "content":    c["text"],
        "doc_type":   "generic",          # set this per your taxonomy
        "source_uri": f"<raw blob uri>",  # pass through from pipeline
        "page_start": c["pages"][0],
        "page_end":   c["pages"][-1],
        "ingest_ts":  "<pipeline run timestamp>",
        "metadata":   "{}"
    }
    blob_name = f"{chunks_prefix}{file_id}-{i:04d}.json"
    container.upload_blob(name=blob_name, data=json.dumps(payload), overwrite=True)

print(f"Wrote {len(chunks)} chunks for {file_id}")
```

### 3.6 Build activity 2b / 2e — Control table upserts

Two notebook (or Script) activities, one before and one after the chunking step:

**Before (insert pending row):**

```python
from pyspark.sql.functions import current_timestamp, lit
row = spark.createDataFrame(
    [(file_id, source_path, source_modified_ts, raw_blob_uri, chunks_prefix, "generic",
      byte_size, page_count, ingest_run_id, None, "pending", None, "pending", None, None, "pending", None, False)],
    ["file_id","source_path","source_modified_ts","raw_blob_uri","chunk_blob_prefix","doc_type",
     "byte_size","page_count","ingest_run_id","ingest_ts","ocr_status","ocr_completed_ts",
     "chunk_status","chunk_count","chunk_completed_ts","index_status","last_error","tombstoned"]
)
row = row.withColumn("ingest_ts", current_timestamp())
row.createOrReplaceTempView("_row")
spark.sql("""
  MERGE INTO control_table_files t
  USING _row s
  ON t.file_id = s.file_id
  WHEN MATCHED THEN UPDATE SET *
  WHEN NOT MATCHED THEN INSERT *
""")
```

**After (mark succeeded):**

```python
spark.sql(f"""
  UPDATE control_table_files
  SET ocr_status='succeeded', ocr_completed_ts=current_timestamp(),
      chunk_status='succeeded', chunk_count={chunk_count}, chunk_completed_ts=current_timestamp()
  WHERE file_id='{file_id}'
""")
```

### 3.7 Pipeline run

1. Publish the pipeline
2. **Run** manually with 1–2 sample files first
3. Watch the activity outputs; fix issues iteratively
4. Once a sample run is green end-to-end: schedule it (e.g. every 30 minutes) or leave on manual for demo

### Phase 3 validation

- [ ] Pipeline run completes with no failures on 5 sample documents
- [ ] `control_table_files` has 5 rows with all status fields = `succeeded`
- [ ] Blob `raw/` container has 5 original files
- [ ] Blob `chunks/` container has multiple JSON chunk files per document
- [ ] Sample chunk JSON inspected and well-formed

---

## Phase 4 — AI Search index

### 4.1 Create the index

In the AI Search portal → **Indexes → + Add index** (or use the REST API for full schema control).

The REST API is easier for getting the integrated vectorizer right. Sample payload:

```json
PUT https://srch-rag-demo-eus.search.windows.net/indexes/idx-rag-documents?api-version=2024-07-01
Content-Type: application/json
api-key: <admin key>

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

> **Critical:** the `vectorizers[0].azureOpenAIParameters.authIdentity` set to `null` means **use the service's system-assigned managed identity**. The role assignment from Phase 1.7 (Cognitive Services OpenAI User on the Foundry resource) is what makes this work. If you used a user-assigned identity instead, set the identity object here. The `resourceUri` uses the Foundry resource's OpenAI-compatible endpoint (`*.openai.azure.com`) — Foundry resources expose this for backwards-compatible tooling like the AI Search vectorizer.

### 4.2 Create the data source

Points the indexer at the Blob `chunks/` container.

```json
PUT https://srch-rag-demo-eus.search.windows.net/datasources/ds-chunks?api-version=2024-07-01

{
  "name": "ds-chunks",
  "type": "azureblob",
  "credentials": { "connectionString": "ResourceId=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<st>;" },
  "container": { "name": "chunks" }
}
```

Using the `ResourceId=...;` connection string enables **managed-identity authentication** — no key needed.

### 4.3 Create the indexer

```json
PUT https://srch-rag-demo-eus.search.windows.net/indexers/ixr-chunks?api-version=2024-07-01

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
POST https://srch-rag-demo-eus.search.windows.net/indexers/ixr-chunks/run?api-version=2024-07-01
```

Then watch status:

```bash
GET https://srch-rag-demo-eus.search.windows.net/indexers/ixr-chunks/status?api-version=2024-07-01
```

A successful run shows `lastResult.status = "success"` and `itemsProcessed` matching the number of chunk JSONs in Blob.

### 4.5 Smoke-test the index

Run a sample query that exercises hybrid + semantic ranker:

```json
POST https://srch-rag-demo-eus.search.windows.net/indexes/idx-rag-documents/docs/search?api-version=2024-07-01

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

## Phase 5 — Copilot Studio agent

### 5.1 Create the agent

1. Open **Copilot Studio**
2. **Create → Agent**
3. Provide a **name** and **description** (generic-friendly: "Knowledge Assistant for <Domain>")
4. **Instructions / system prompt** — a starter:

   > You are a knowledge assistant grounded on the customer's document corpus.
   > Answer concisely and cite the source document for every factual claim.
   > If the knowledge source does not contain enough information to answer
   > confidently, say so and offer to escalate.

### 5.2 Add AI Search as a knowledge source

1. Inside the agent: **Knowledge → + Add knowledge → Azure AI Search**
2. **Authentication:** Microsoft Entra (uses the connecting user's identity) **or** an admin key (simpler for demo)
3. **Search endpoint:** `https://srch-rag-demo-eus.search.windows.net`
4. **Index name:** `idx-rag-documents`
5. **Enable semantic search:** **ON** ← critical
6. **Title field:** `doc_id` (or a friendly name field if you add one)
7. **URL field:** `source_uri` (this enables citation linkback)
8. **Content field:** `content`
9. Save

### 5.3 Configure generative answers

1. **Generative AI → Settings**
2. Set **Knowledge source** = the AI Search source you just added
3. Generative answers: **Enabled**
4. (Optional) Set fallback behavior when no knowledge is found

### 5.4 Test inside Copilot Studio

Use the **Test** pane on the right to ask questions:

- A direct factual question that should hit a single chunk
- A semantic / paraphrased question
- A multi-document question
- A question deliberately outside the corpus (test fallback)

Confirm answers include **citations** that link back to the original document in Blob.

### 5.5 Publish to Teams

1. **Publish → Channels → Microsoft Teams**
2. Add your tenant
3. (One-time) Power Platform admin approves the deployment
4. Install the agent in Teams via the generated link

### 5.6 Publish to M365 Copilot

1. **Publish → Channels → Microsoft 365 Copilot**
2. (One-time) M365 admin enables the agent in the M365 Copilot agent gallery
3. Locate the agent in **M365 Copilot → Agents** in any M365 host (Word, Outlook, Teams, copilot.microsoft.com)

### Phase 5 validation

- [ ] Test pane returns grounded answers with citations
- [ ] Teams channel published and reachable from a Teams chat
- [ ] M365 Copilot channel published and reachable in the agent gallery
- [ ] End-to-end: question in Teams → answer with clickable citation → opens raw file in Blob

---

## Post-deployment checklist

Once all five phases validate green, proceed to [05-testing.md](./05-testing.md) to run the full test suite.

- [ ] All Phase 1–5 validation boxes checked
- [ ] Pipeline scheduled (not just on-demand)
- [ ] Indexer scheduled
- [ ] Cost alerts configured on the resource group
- [ ] Key Vault secrets documented + rotation plan
- [ ] Backup / disaster-recovery plan written (at minimum: re-runnable pipeline from `raw/` blob)
- [ ] Customer + Microsoft owners identified for ongoing operation

---

*Last updated: 2026-05-21*

# 03b — Fabric setup (manual — both deployment paths)

The Fabric layer of this pattern is **always manual**. Neither the manual Azure path ([03-deployment-manual.md](./03-deployment-manual.md)) nor the Bicep-automated path ([04-deployment-automated.md](./04-deployment-automated.md)) can provision Fabric items today — Fabric workspaces, Lakehouses, OneLake shortcuts, and Data Pipelines have no Bicep/ARM resource provider as of this pattern's publication, and the [Fabric REST APIs](https://learn.microsoft.com/en-us/rest/api/fabric/articles/) for items are only partially covered for automation.

> **Run this doc after Azure platform layer is up.** You need the Azure resources from [03-deployment-manual.md § Phase 1](./03-deployment-manual.md#phase-1--foundation) (manual) **or** the deployment outputs from [04-deployment-automated.md § Step 3](./04-deployment-automated.md) (automated) before you can wire the Fabric pipeline to them. Specifically you need: the storage account name, the Document Intelligence endpoint, and a Key Vault that holds the DI key.

> **Time budget.** First-time Fabric build: **2–3 hours** end-to-end. Subsequent rebuilds in the same tenant: **45–60 minutes** once the workspace identity, connections, and notebook artifacts can be reused.

---

## What you'll build

```
Fabric workspace (ws-rag-<env>)
├── Workspace identity (auto-created service principal, used for Blob + DI auth)
├── Connections
│   └── Azure Blob Storage connection (writes raw/ + chunks/ via workspace identity)
├── Lakehouse: lh_rag_<env>
│   ├── Files/
│   │   └── source_docs/          ← OneLake shortcut to the customer source
│   └── Tables/
│       ├── control_table_files   ← Delta state table (this pattern's source of truth)
│       └── _tmp_new_files        ← per-run handoff table from Lookup → ForEach
├── Notebooks
│   ├── nb_create_control_table   ← run once
│   ├── nb_lookup_new_files       ← called from pipeline activity [1]
│   ├── nb_ocr_chunk_upload       ← called from pipeline activity [2c]:
│   │                              calls Document Intelligence via Python SDK +
│   │                              workspace identity, chunks the result, and
│   │                              uploads chunk JSON to Blob — all in one notebook
│   └── nb_update_control_table   ← called from pipeline activities [2b], [2d], on-error
└── Data Pipeline: pl_ingest_docs
    ├── [1]  Notebook activity     → nb_lookup_new_files (writes _tmp_new_files)
    ├── [1′] Lookup activity       → read _tmp_new_files rows for the ForEach
    └── [2]  ForEach over Lookup output:
        ├── [2a] Copy data             → OneLake source → Blob raw/  (workspace-identity auth)
        ├── [2b] Notebook              → nb_update_control_table (status=pending)
        ├── [2c] Notebook              → nb_ocr_chunk_upload (DI → chunks/ JSON)
        ├── [2d] Notebook              → nb_update_control_table (status=succeeded)
        └── On-error handler           → nb_update_control_table (status=failed, last_error)
```

> **Why no Web activity / Until / child pipeline?** Two real Fabric constraints shape this design:
>
> 1. **The Fabric Web activity has no `System Assigned Managed Identity` + `Resource` fields like ADF does.** It only takes a Connection from Manage connections and gateways, and the Web v2 connector's `Workspace identity` auth is currently supported in Dataflow Gen2 only, not in pipelines (see the [Web v2 connector overview](https://learn.microsoft.com/fabric/data-factory/connector-web-overview) and [ADF/Fabric connector parity](https://learn.microsoft.com/fabric/data-factory/connector-parity)).
> 2. **You cannot nest `Until` inside `ForEach`** (see [ForEach activity limitations](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds)) — which is the natural pattern for polling Document Intelligence's async `analyze` operation from a pipeline activity.
>
> Both are avoided by calling Document Intelligence from a **notebook** using the official [`azure-ai-documentintelligence`](https://learn.microsoft.com/python/api/overview/azure/ai-documentintelligence-readme) SDK with `DefaultAzureCredential`, which resolves to the workspace identity inside Fabric notebooks. The SDK's long-running-operation poller handles waiting for OCR to finish internally, so the pipeline doesn't need an `Until` loop. Folding OCR + chunking + upload into one notebook also avoids spinning up Spark twice per file.

> **All auth is managed identity.** API keys are disabled across Azure Storage (`allowSharedKeyAccess=false`), Document Intelligence (`disableLocalAuth=true`), AI Search (`disableLocalAuth=true`), and Foundry (`disableLocalAuth=true`). The Fabric workspace identity is the principal that authenticates every cross-service call this pipeline makes. There are no secrets to store or rotate.

---

## Phase F0 — Tenant & capacity prerequisites

Before you can build anything Fabric-side, confirm the following with your Fabric tenant admin. None of these are owned by the builder; if any are missing you'll be blocked at workspace or pipeline creation.

### F0.1 Tenant settings to confirm

In **Fabric Admin Portal → Tenant settings**:

| Setting | Required state | Why |
|---|---|---|
| **Users can create Fabric items** | Enabled (for your security group) | Lets you create Lakehouse, Notebook, Pipeline |
| **OneLake shortcuts** → **Users can create OneLake shortcuts** | Enabled | Required for [Phase F4 — shortcut to source](#phase-f4--attach-the-source-via-onelake-shortcut) |
| **Service principals can use Fabric APIs** | Enabled if you plan to automate later (optional for this build) | Future-proofing |
| **Workspace identity** → **Service principals and workspace identities can access Fabric APIs** | Enabled | Required so the workspace identity (Phase F2) can be used in connections |
| **Data Factory** → **Allow Fabric Data Factory pipelines** | Enabled | Required for the ingest pipeline |

Reference: [Fabric tenant settings](https://learn.microsoft.com/en-us/fabric/admin/about-tenant-settings).

### F0.2 Capacity

You need a **Fabric F-SKU capacity** assigned to a tenant. The builder needs **Capacity Admin** or to be granted permission to assign the new workspace to that capacity.

| SKU | Use |
|---|---|
| **F2** | Demo only; pipelines may queue under load |
| **F4 / F8** | Recommended demo / pilot — comfortably runs the chunking notebook |
| **F16+** | Production — handles concurrent pipeline runs + ad-hoc notebook work |

Trial capacity (60-day) is acceptable for an initial build, but plan to move to an F-SKU before the demo for SLA reasons. See [Buy a Microsoft Fabric subscription](https://learn.microsoft.com/fabric/enterprise/buy-subscription) and [Plan your capacity size](https://learn.microsoft.com/fabric/enterprise/plan-capacity).

---

## Phase F1 — Create the workspace

In the **[Fabric portal](https://app.fabric.microsoft.com/)**:

1. **Workspaces** (left nav) → **+ New workspace**
2. **Name:** `ws-rag-<env>` (e.g. `ws-rag-demo`, `ws-rag-prod`)
3. **Description:** "RAG knowledge-base ingestion workspace — owns Lakehouse + Data Pipeline"
4. **Advanced** → **License mode** → **Fabric capacity** → select your capacity from F0.2
5. **Default storage format** → leave as **Small dataset storage format** (lakehouse uses Delta regardless)
6. **Apply**

> **Do not use a "My workspace".** My workspaces cannot have a workspace identity (Phase F2) and cannot be shared. Personal workspaces are not viable for this pattern.

Confirm the workspace appears in **Workspaces** with your capacity name shown.

Record `workspaceId` and `workspaceName` in `demo-ids.local.json` under `fabric.workspaceId` / `fabric.workspaceName`. The workspace ID is in the URL after `/groups/`.

---

## Phase F2 — Create the workspace identity

This is the **single most important Fabric setup step** in this pattern. The workspace identity is a managed service principal that lets your pipeline authenticate to Azure Blob Storage (and other Entra-protected services) **without keys or secrets**, using trusted workspace access. Without it you fall back to account keys (insecure) or SAS tokens (operationally painful).

Reference: [Fabric workspace identity overview](https://learn.microsoft.com/en-us/fabric/security/workspace-identity).

1. Open the workspace → click the **Workspace settings** (gear) icon (top right)
2. Select the **Workspace identity** tab
3. Click **+ Workspace identity**
4. Wait for the state to flip to **Active** (typically <2 minutes)
5. Note the identity **Name** (matches workspace name: `ws-rag-<env>`) and **ID** (a GUID)

Behind the scenes, Fabric creates a service principal + app registration in Microsoft Entra ID. You can see it in the Azure portal under **Microsoft Entra ID → Enterprise applications** filtered by the workspace name — **do not modify it there**.

> **Trusted workspace access.** Because the workspace has an identity, OneLake shortcuts and pipeline activities running in this workspace can use **trusted workspace access** to reach firewall-protected Azure Data Lake Storage Gen2 / Blob accounts. This is the only path that works cleanly for production environments where the storage account has the public network disabled. See [Trusted workspace access](https://learn.microsoft.com/en-us/fabric/security/security-trusted-workspace-access).

### F2.1 Grant the workspace identity the required roles

The pipeline writes raw files to `raw/` and chunk JSON to `chunks/`, and it calls Document Intelligence with a bearer token. With all API keys disabled, the workspace identity needs three role assignments — grant them now before pipeline-build steps that depend on them.

From the **Azure portal** (or `az cli` — both shown):

```bash
# Identities + scopes
WS_OBJID=<workspace-identity-object-id>   # Microsoft Entra ID → Enterprise applications → search workspace name
ST_RES_ID=$(az storage account show --name <storage-account> -g <rg> --query id -o tsv)
DI_RES_ID=$(az cognitiveservices account show --name <di-resource> -g <rg> --query id -o tsv)

# 1. Write raw/ and chunks/ from Copy and chunk-upload activities
az role assignment create \
  --assignee-object-id $WS_OBJID --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope $ST_RES_ID

# 2. Call Document Intelligence prebuilt-read from a notebook with a bearer token
#    (nb_ocr_chunk_upload uses DefaultAzureCredential, which resolves to the
#     workspace identity inside Fabric notebooks)
az role assignment create \
  --assignee-object-id $WS_OBJID --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope $DI_RES_ID
```

> **Why "Cognitive Services User" and not "Cognitive Services Contributor"?** User grants data-plane read/invoke on the analyze endpoint. Contributor includes management-plane permissions (create / delete deployments) that the pipeline doesn't need.

> **Propagation:** Azure role assignments to Fabric workspace identities can take up to **15 minutes** to be honored end-to-end (Fabric token cache + Azure RBAC cache). If your first pipeline run fails with `401 Unauthorized` or `403 Forbidden`, wait and retry before debugging further.

---

## Phase F3 — Create the Lakehouse

1. Inside the workspace: **+ New item** (or **+ New** depending on UI version) → **Lakehouse**
2. **Name:** `lh_rag_<env>` (lowercase, underscores — Lakehouse name allows underscores; do NOT use hyphens)
3. **Enable schemas** → leave **off** for this pattern (the control table doesn't need a custom schema)
4. **Create**

When created, Fabric automatically provisions:

- The Lakehouse explorer (Files + Tables)
- A **SQL analytics endpoint** (read-only T-SQL access — useful for ad-hoc inspection)
- A storage location under OneLake at `https://onelake.dfs.fabric.microsoft.com/<workspaceId>/<lakehouseId>/`

Record `lakehouseId`, `lakehouseName`, and `lakehouseSqlEndpoint` in `demo-ids.local.json`. The SQL endpoint hostname is shown in the Lakehouse's **Settings → SQL analytics endpoint** pane.

Reference: [What is a lakehouse in Microsoft Fabric?](https://learn.microsoft.com/en-us/fabric/data-engineering/lakehouse-overview).

---

## Phase F4 — Attach the source via OneLake shortcut

The pattern is source-agnostic: the OneLake shortcut layer normalizes whatever upstream document store the customer uses (SharePoint Online, ADLS Gen2, S3, GCS, etc.) into a unified `Files/source_docs/` location that the pipeline reads from.

| Source | Shortcut type | Reference |
|---|---|---|
| **SharePoint Online document library** | OneLake shortcut → Microsoft 365 / Microsoft Dataverse → SharePoint Online | [Create a Dataverse / SharePoint shortcut](https://learn.microsoft.com/en-us/fabric/onelake/onelake-shortcuts) |
| **Azure Data Lake Storage Gen2** | OneLake shortcut → ADLS Gen2 | [Create an ADLS Gen2 shortcut](https://learn.microsoft.com/en-us/fabric/onelake/create-adls-shortcut) |
| **Azure Blob (separate account)** | OneLake shortcut → ADLS Gen2 (Blob is exposed via the dfs endpoint) | Same as above |
| **Amazon S3 / GCS** | OneLake shortcut → S3 / GCS | [Create an S3 shortcut](https://learn.microsoft.com/en-us/fabric/onelake/create-s3-shortcut) |
| **File share / FTP / mailbox** | No shortcut — use a scheduled **Copy data** pipeline activity to land files into `Files/source_docs/` | [Copy data activity](https://learn.microsoft.com/en-us/fabric/data-factory/copy-data-activity) |

### F4.1 Create the shortcut (default demo source: SharePoint Online)

Reference: [Create an internal OneLake shortcut](https://learn.microsoft.com/en-us/fabric/onelake/create-onelake-shortcut) (the menu paths are the same for external sources — only the connector selection differs).

1. Open the Lakehouse → in the **Explorer** pane, right-click **Files** → **New shortcut**
2. Under **External sources**, choose your source type (for the default demo: **Microsoft 365 → SharePoint Online**, or **Azure Data Lake Storage Gen2** if you already have docs there)
3. **Create a connection:**
   - **URL:** for SharePoint, the site URL (e.g. `https://contoso.sharepoint.com/sites/HRPolicies`). For ADLS Gen2, the `dfs.core.windows.net` endpoint of the storage account.
   - **Authentication kind:**
     - **For SharePoint:** **Organizational account** — sign in as a user with at least Read on the document library. (Workspace identity is **not yet supported** as the authentication kind for SharePoint Online shortcuts; this is the one place in the Fabric layer where a user identity is required.)
     - **For ADLS Gen2 / Blob:** **Workspace identity** (preferred — requires F2 + an RBAC role on the source storage). Fallback: **Organizational account** or **Account key**.
   - **Privacy level:** Organizational
4. Select the document library / folder you want to expose (e.g. `Shared Documents/Policies`)
5. **Shortcut name:** `source_docs`
6. **Create**

Confirm `Files/source_docs/` now appears in the Lakehouse Explorer and you can browse the source documents from inside Fabric.

### F4.2 Drop a sample document set into the source

For a clean first build, place **5–10 representative documents** in the source location. Cover the file types, lengths, and document categories the production corpus will contain (PDFs, DOCX, scans, mixed-language, etc.). Sample diversity matters more than volume for the initial build.

If the shortcut points at an already-populated source, skip this — work with whatever is there.

> **Refresh lag.** Shortcut content listing can lag a few minutes behind the source. If you don't see new files, click the refresh icon on the Lakehouse explorer.

---

## Phase F5 — Create the control Delta table

The control table is the pattern's source-of-truth for file processing state. One row per source file. It enables idempotent re-runs, incremental processing, audit/observability, and pipeline failure recovery.

### F5.1 Create the notebook `nb_create_control_table`

1. Inside the workspace: **+ New item → Notebook** → name `nb_create_control_table`
2. In the notebook, attach the lakehouse: **Add lakehouse** (left pane) → select `lh_rag_<env>` → **Add**
3. Paste the following cell and run it once:

```python
from pyspark.sql.types import (
    StructType, StructField, StringType, LongType, IntegerType,
    TimestampType, BooleanType,
)

schema = StructType([
    StructField("file_id",             StringType(),    False),
    StructField("source_path",         StringType(),    True),
    StructField("source_modified_ts",  TimestampType(), True),
    StructField("raw_blob_uri",        StringType(),    True),
    StructField("chunk_blob_prefix",   StringType(),    True),
    StructField("doc_type",            StringType(),    True),
    StructField("byte_size",           LongType(),      True),
    StructField("page_count",          IntegerType(),   True),
    StructField("ingest_run_id",       StringType(),    True),
    StructField("ingest_ts",           TimestampType(), True),
    StructField("ocr_status",          StringType(),    True),
    StructField("ocr_completed_ts",    TimestampType(), True),
    StructField("chunk_status",        StringType(),    True),
    StructField("chunk_count",         IntegerType(),   True),
    StructField("chunk_completed_ts",  TimestampType(), True),
    StructField("index_status",        StringType(),    True),
    StructField("last_error",          StringType(),    True),
    StructField("tombstoned",          BooleanType(),   True),
])

empty = spark.createDataFrame([], schema)
empty.write.format("delta").mode("overwrite").saveAsTable("control_table_files")
print("control_table_files created.")
```

> **Why `overwrite`?** Idempotent setup — re-running drops & recreates the empty table. Once the pipeline has produced rows, never re-run this notebook in `overwrite` mode in a live environment; use `mode("ignore")` after first build to make the cell a true no-op.

4. Confirm the table appears under **Tables** in the Lakehouse explorer and is queryable from the SQL analytics endpoint:

```sql
-- Run this in the SQL analytics endpoint (from the Lakehouse's "SQL analytics endpoint" tab)
SELECT * FROM control_table_files;
-- Should return 0 rows with the full column list.
```

---

## Phase F6 — Create the Blob connection

Fabric pipelines authenticate to external services through **connections**. For this pattern you only need to pre-create **one connection** — Azure Blob Storage — for the Copy activity. Document Intelligence is called from a Fabric notebook (`nb_ocr_chunk_upload`) using the `azure-ai-documentintelligence` Python SDK + `DefaultAzureCredential`, which resolves to the workspace identity automatically — so no DI connection, no Key Vault reference, and no Web activity is required.

Reference: [Connector overview](https://learn.microsoft.com/fabric/data-factory/connector-overview) and [Set up your Azure Blob Storage connection](https://learn.microsoft.com/fabric/data-factory/connector-azure-blob-storage).

### F6.1 Azure Blob Storage connection (for Copy activity to raw/)

1. **Fabric portal → top-right gear icon → Manage connections and gateways → Connections → + New**
2. **Connection type:** **Azure Blob Storage**
3. **Account name or URL:** `https://<storage-account>.blob.core.windows.net`
4. **Authentication kind:** **Organizational account** (simplest for build-time — you authenticate as yourself; pipeline runtime then resolves to the workspace identity because of [F2.1](#f21-grant-the-workspace-identity-the-required-roles)) — or **Service principal** for explicit SP auth.
   - **Do not** select **Account key** — shared-key access is disabled on the storage account.
5. **Connection name:** `blob-rag-<env>`
6. **Create**

> The workspace identity already has Storage Blob Data Contributor from Phase F2.1. If you choose Service principal here instead, grant that SP the same role.

### F6.2 (Optional) Azure Key Vault references for connection credentials

**You do NOT need this pattern.** It's documented here for completeness because it sometimes comes up when extending the pattern to additional connectors that require a stored credential. With API keys disabled across all Azure AI services this pattern uses, no secret needs to be retrieved at runtime for the default flows.

If you later add a Snowflake / SQL Server / etc. connection that requires a password, you can store that password in Key Vault and reference it:

1. Gear icon → **Manage connections and gateways → Azure Key Vault references → + New**
2. **Reference alias:** `akv-rag-<env>`
3. **Account Name:** your Key Vault name
4. Authenticate with OAuth 2.0 (your account needs at least **Key Vault Secrets User** + **Key Vault Certificate User** on the vault)
5. **Create**

Then in supported connectors that take a credential, use the **AKV reference** icon next to the secret field. Full list of supported connectors and authentication types: [Configure Azure Key Vault references](https://learn.microsoft.com/fabric/data-factory/azure-key-vault-reference-configure#supported-connectors-and-authentication-types).

> **Limitation.** AKV references **only populate credentials inside a Fabric *connection definition*** — they cannot inject a secret into a Web activity's custom request header. For this pattern that's fine: the Web activity that calls DI uses managed-identity authentication and never sees a key.

### F6.3 Validation — write a test file from a notebook

In a quick scratch notebook (with the lakehouse attached), confirm the workspace identity can reach Blob:

```python
blob_account = "<storage-account>"
container    = "raw"

df = spark.createDataFrame([("hello", 1)], ["msg", "n"])
df.write.mode("overwrite").csv(
    f"abfss://{container}@{blob_account}.dfs.core.windows.net/_test_workspace_identity/"
)
print("OK — wrote to Blob via workspace identity.")
```

If this throws `401 Unauthorized` or `403 Forbidden`, the F2.1 role assignment hasn't propagated yet (wait up to 15 min) or the workspace identity isn't on the role. Re-check `Microsoft Entra ID → Enterprise applications → <workspace name> → Object ID` matches what was granted the role.

Clean up the test path after success:

```python
notebookutils.fs.rm(
    f"abfss://{container}@{blob_account}.dfs.core.windows.net/_test_workspace_identity/",
    recurse=True,
)
```

---

## Phase F7 — Author the pipeline notebooks

The pipeline calls three notebooks. Create them now so the pipeline activities in Phase F8 can reference them.

### F7.1 `nb_lookup_new_files`

Parameters expected (set as **parameters cell** at the top — the pipeline passes them in):

- `source_path` (string) — the Files-relative path to scan, e.g. `Files/source_docs/`

```python
# Parameters
source_path = "Files/source_docs/"   # default; overridden by pipeline

# Imports
import json
from pyspark.sql.functions import col, md5, concat_ws, regexp_replace

# Discover files in the source (binaryFile reader recursively walks the folder)
src = (
    spark.read.format("binaryFile")
        .option("recursiveFileLookup", "true")
        .load(source_path)
        .select("path", "modificationTime", "length")
        .withColumnRenamed("path",             "source_path")
        .withColumnRenamed("modificationTime", "source_modified_ts")
        .withColumnRenamed("length",           "byte_size")
)

# binaryFile reader returns ABSOLUTE abfss URIs in source_path, e.g.
#   abfss://<workspaceId>@onelake.dfs.fabric.microsoft.com/<lakehouseId>/Files/source_docs/<file>
# The pipeline Copy activity binds @item().source_path as a path RELATIVE to the
# Lakehouse Files/ root, so we strip the prefix here. Without this strip, the
# Copy activity ends up looking for <lakehouseId>/Files/abfss:/<lakehouseId>/...
# which 404s with PathNotFound — see 06-troubleshooting.md § 3.5.
src = src.withColumn(
    "source_path",
    regexp_replace(col("source_path"), r"^.*/Files/", ""),
)

# Stable file_id = md5(source_path || source_modified_ts)
src = src.withColumn(
    "file_id",
    md5(concat_ws("|", col("source_path"), col("source_modified_ts").cast("string"))),
)

# Anti-join against control table to find new files
ctrl = spark.table("control_table_files").select("file_id")
new_files = src.join(ctrl, on="file_id", how="left_anti")

# Persist for the pipeline's Lookup activity to read
(new_files
    .select("file_id", "source_path",
            col("source_modified_ts").cast("string").alias("source_modified_ts"),
            "byte_size")
    .write.format("delta").mode("overwrite").saveAsTable("_tmp_new_files"))

# Return JSON-serialized summary as the notebook exit value.
# notebookutils.notebook.exit(value) takes a STRING; the pipeline receives it at
# @activity('lookup_new_files').output.result.exitValue
exit_payload = json.dumps({"new_count": new_files.count()})
notebookutils.notebook.exit(exit_payload)
```

> **`notebookutils.notebook.exit(value)`** is the current Fabric API for returning data from a notebook activity. The legacy `mssparkutils` namespace still works for backwards compatibility but is being retired — always use `notebookutils` for new code. The value passed to `exit()` **must be a string**; serialize complex data with `json.dumps(...)` and parse on the consumer side. See [NotebookUtils notebook run and orchestration](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-notebook-run#exit-a-notebook).
>
> **Why a staging Delta table instead of returning the file list inline?** The notebook activity's `exitValue` is a single string, and Spark `Row` objects (with timestamps, nested types) don't round-trip cleanly through `json.dumps`. The conventional Fabric pipeline pattern is: have the notebook persist row data to a Delta table, then run a **Lookup activity** ([Phase F8.2](#f82-activity-1-lookup-read-_tmp_new_files-for-the-foreach)) against that table to feed the ForEach. This also keeps file metadata typed and queryable for debugging.

### F7.2 `nb_ocr_chunk_upload`

This notebook calls Document Intelligence, chunks the resulting text, and uploads chunk JSON to Blob — all in one Spark session per file. It uses the official [`azure-ai-documentintelligence`](https://learn.microsoft.com/python/api/overview/azure/ai-documentintelligence-readme) Python SDK with `DefaultAzureCredential`, which resolves to the workspace identity inside Fabric notebooks. The SDK's long-running-operation poller waits for DI's async `analyze` operation to finish, so the pipeline doesn't need an `Until` loop.

Parameters expected:

- `file_id` (string)
- `raw_blob_uri` (string)
- `chunks_account` (string)
- `chunks_container` (string) — `chunks`
- `chunks_prefix` (string) — typically `f"{file_id}/"`
- `di_endpoint` (string) — e.g. `https://di-rag-demo-eus.cognitiveservices.azure.com`

```python
# Parameters (overridden by pipeline)
file_id          = ""
raw_blob_uri     = ""
chunks_account   = ""
chunks_container = "chunks"
chunks_prefix    = ""
di_endpoint      = ""

# Install required packages (cached in the session after first install)
%pip install azure-ai-documentintelligence==1.0.0 azure-storage-blob==12.21.0 azure-identity==1.17.0 tiktoken==0.7.0 --quiet
```

```python
import json
import tiktoken
from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.ai.documentintelligence.models import AnalyzeDocumentRequest
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

# Chunking knobs — adjust per corpus
CHUNK_TOKENS    = 1000
OVERLAP_TOKENS  = 200
ENCODING        = tiktoken.encoding_for_model("gpt-4o")

# 1. Call Document Intelligence with workspace-identity bearer token.
#    DefaultAzureCredential resolves to the workspace identity in Fabric notebooks.
#    .result() polls the async analyze operation internally until done.
cred       = DefaultAzureCredential()
di_client  = DocumentIntelligenceClient(endpoint=di_endpoint, credential=cred)
poller     = di_client.begin_analyze_document(
    model_id="prebuilt-read",
    body=AnalyzeDocumentRequest(url_source=raw_blob_uri),
)
di_result  = poller.result().as_dict()

# 2. Page-aware chunker with token budget + overlap
def chunk_pages(pages, max_tok=CHUNK_TOKENS, overlap=OVERLAP_TOKENS):
    chunks = []
    buf, buf_pages, buf_tok = [], [], 0
    for page in pages:
        page_text = page["content"]
        page_no   = page["pageNumber"]
        page_tok  = len(ENCODING.encode(page_text))
        if buf_tok + page_tok > max_tok and buf:
            chunks.append({"text": "\n\n".join(buf), "pages": buf_pages})
            buf       = [buf[-1]] if overlap > 0 else []
            buf_pages = [buf_pages[-1]] if overlap > 0 else []
            buf_tok   = len(ENCODING.encode(buf[0])) if buf else 0
        buf.append(page_text)
        buf_pages.append(page_no)
        buf_tok += page_tok
    if buf:
        chunks.append({"text": "\n\n".join(buf), "pages": buf_pages})
    return chunks

# DI 4.0 result schema: pages live under "pages" with "lines[].content"
raw_pages = di_result.get("pages", [])
flat_pages = [
    {
        "pageNumber": p.get("pageNumber") or p.get("page_number"),
        "content":    " ".join(line["content"] for line in p.get("lines", [])),
    }
    for p in raw_pages
]
chunks = chunk_pages(flat_pages)

# 3. Upload one JSON per chunk to Blob chunks/<chunks_prefix>
svc = BlobServiceClient(
    account_url=f"https://{chunks_account}.blob.core.windows.net",
    credential=cred,
)
container = svc.get_container_client(chunks_container)

for i, c in enumerate(chunks):
    payload = {
        "id":         f"{file_id}-{i:04d}",
        "doc_id":     file_id,
        "chunk_id":   i,
        "content":    c["text"],
        "doc_type":   "generic",
        "source_uri": raw_blob_uri,
        "page_start": c["pages"][0],
        "page_end":   c["pages"][-1],
        "ingest_ts":  spark.sql("SELECT current_timestamp() AS ts").first()["ts"].isoformat(),
        "metadata":   "{}",
    }
    blob_name = f"{chunks_prefix}{file_id}-{i:04d}.json"
    container.upload_blob(name=blob_name, data=json.dumps(payload), overwrite=True)

notebookutils.notebook.exit(json.dumps({"chunk_count": len(chunks)}))
```

> **Why this design over a pipeline Web activity?** See the ["Why no Web activity / Until / child pipeline?" callout](#what-youll-build). In short: the Fabric Web activity doesn't expose ADF's `System Assigned Managed Identity` + `Resource` configuration, so calling Entra-protected Cognitive Services endpoints with workspace identity is awkward from a pipeline activity. Calling the same endpoint from a notebook via `DefaultAzureCredential` is well-supported and the SDK transparently handles the async polling that would otherwise require an `Until` loop (which can't nest inside `ForEach`).

> **Auth note for `DefaultAzureCredential` inside Fabric notebooks.** When run inside a Fabric notebook activity in a workspace with a workspace identity, `DefaultAzureCredential` resolves to the workspace identity automatically. This is why [F2.1](#f21-grant-the-workspace-identity-the-required-roles) (granting **Storage Blob Data Contributor** on Storage and **Cognitive Services User** on Document Intelligence) is the load-bearing step for this notebook to work without keys.

### F7.3 `nb_update_control_table`

Parameters expected:

- `file_id` (string)
- `source_path` (string, optional)
- `source_modified_ts` (string ISO timestamp, optional)
- `raw_blob_uri` (string, optional)
- `chunks_prefix` (string, optional)
- `byte_size` (long, optional)
- `page_count` (int, optional)
- `ingest_run_id` (string)
- `chunk_count` (int, optional)
- `status` (string) — one of `pending`, `succeeded`, `failed`
- `last_error` (string, optional)

```python
# Parameters
file_id            = ""
source_path        = None
source_modified_ts = None
raw_blob_uri       = None
chunks_prefix      = None
byte_size          = None
page_count         = None
ingest_run_id      = ""
chunk_count        = None
status             = "pending"   # pending | succeeded | failed
last_error         = None
```

```python
from pyspark.sql.functions import current_timestamp

# Build a single-row DataFrame
row = spark.createDataFrame(
    [(
        file_id, source_path, source_modified_ts, raw_blob_uri, chunks_prefix,
        "generic", byte_size, page_count, ingest_run_id, None,
        status, None, status, chunk_count, None, status, last_error, False,
    )],
    [
        "file_id","source_path","source_modified_ts","raw_blob_uri","chunk_blob_prefix",
        "doc_type","byte_size","page_count","ingest_run_id","ingest_ts",
        "ocr_status","ocr_completed_ts","chunk_status","chunk_count",
        "chunk_completed_ts","index_status","last_error","tombstoned",
    ],
).withColumn("ingest_ts", current_timestamp())

if status == "succeeded":
    row = (
        row.withColumn("ocr_completed_ts", current_timestamp())
           .withColumn("chunk_completed_ts", current_timestamp())
    )

row.createOrReplaceTempView("_row")

spark.sql("""
  MERGE INTO control_table_files t
  USING _row s
  ON  t.file_id = s.file_id
  WHEN MATCHED THEN UPDATE SET
      ocr_status         = s.ocr_status,
      ocr_completed_ts   = CASE WHEN s.ocr_status = 'succeeded' THEN s.ocr_completed_ts ELSE t.ocr_completed_ts END,
      chunk_status       = s.chunk_status,
      chunk_count        = COALESCE(s.chunk_count, t.chunk_count),
      chunk_completed_ts = CASE WHEN s.chunk_status = 'succeeded' THEN s.chunk_completed_ts ELSE t.chunk_completed_ts END,
      index_status       = s.index_status,
      last_error         = s.last_error
  WHEN NOT MATCHED THEN INSERT *
""")

import json
notebookutils.notebook.exit(json.dumps({"file_id": file_id, "status": status}))
```

---

## Phase F8 — Build the Data Pipeline

1. Inside the workspace: **+ New item → Data pipeline** → name `pl_ingest_docs` → **Create**
2. Open the pipeline. In the empty canvas, select the **Variables** tab (bottom pane) and add a single string variable:

| Variable | Type | Default value |
|---|---|---|
| `raw_blob_uri` | string | (leave blank) |

> **Why a pipeline variable inside a parallel ForEach?** Setting a pipeline variable from inside a parallel ForEach can race — the variable is global to the pipeline run, not scoped per iteration. **This pattern avoids the race** by computing the per-iteration blob URI inline (`@concat(...)`) directly into each downstream activity's parameters rather than via `Set variable`. The `raw_blob_uri` variable above is declared only so that older versions of the pipeline JSON validate; it isn't written to at runtime in the default design below. If you prefer the readability of a Set variable activity, set the ForEach's `Sequential = On` to serialize iterations (at a cost of throughput).

Now add the activities:

### F8.1 Activity [1] — Lookup new files (Notebook)

| Field | Value |
|---|---|
| **General → Name** | `lookup_new_files` |
| **Settings → Notebook** | `nb_lookup_new_files` |
| **Settings → Base parameters** | `source_path` = `Files/source_docs/` |

Reference: [Transform data by running a notebook (Fabric)](https://learn.microsoft.com/fabric/data-factory/notebook-activity).

### F8.2 Activity [1′] — Lookup (read `_tmp_new_files` for the ForEach)

The notebook persisted the new-file list to `_tmp_new_files`. A pipeline **Lookup** activity reads it back as a typed row array the ForEach can iterate.

Drag a **Lookup** activity after `lookup_new_files`. Connect with the green (success) arrow.

| Field | Value |
|---|---|
| **General → Name** | `lookup_new_files_rows` |
| **Settings → Connection** | `lh_rag_<env>` (Lakehouse) — use the SQL analytics endpoint flavor |
| **Settings → Use query** | **Query** |
| **Settings → Query** | `SELECT file_id, source_path, source_modified_ts, byte_size FROM _tmp_new_files` |
| **Settings → First row only** | **Off** (we want all rows) |

The output is then bound as `@activity('lookup_new_files_rows').output.value` (an array).

### F8.3 Activity [2] — ForEach over new files

Drag a **ForEach** activity onto the canvas after `lookup_new_files_rows`. Connect them with the green (success) arrow.

| Field | Value |
|---|---|
| **General → Name** | `foreach_new_file` |
| **Settings → Items** | `@activity('lookup_new_files_rows').output.value` |
| **Settings → Sequential** | **Off** for parallelism; cap with **Batch count** = 4 for the demo (raise per capacity headroom) |

Inside the ForEach, add the following four activities in sequence:

### F8.4 Activity [2a] — Copy data (OneLake source → Blob raw/)

Inside the ForEach, **Add activity → Copy data**.

| Field | Value |
|---|---|
| **General → Name** | `copy_raw_to_blob` |
| **Source → Connection** | `lh_rag_<env>` (Lakehouse) |
| **Source → Root folder** | `Files` |
| **Source → File path** | `@item().source_path` (this is a path **relative to the Files root**, e.g. `source_docs/<filename>` — the lookup notebook strips the absolute `abfss://...` prefix before writing to `_tmp_new_files`) |
| **Source → File format** | **Binary** (preserves bytes) |
| **Sink → Connection** | `blob-rag-<env>` (from F6.1) |
| **Sink → Container** | `raw` |
| **Sink → File path** | `@concat(item().file_id, '/', last(split(item().source_path, '/')))` |
| **Sink → File format** | **Binary** |

Reference: [Configure Lakehouse in a copy activity](https://learn.microsoft.com/fabric/data-factory/connector-lakehouse-copy-activity).

> **If you see `PathNotFound`** with a path that contains `Files/abfss:/...`, the lookup notebook is writing absolute URIs to `_tmp_new_files` instead of relative paths. The `regexp_replace(...)` line in [F7.1](#f71-nb_lookup_new_files) is the fix — see also [06-troubleshooting.md § 3.5](./06-troubleshooting.md#35-copy-activity-fails-with-pathnotfound-and-an-abfss-uri-in-the-path).

### F8.5 Activity [2b] — Update control table (pending)

**Add activity → Notebook** after the Copy.

| Field | Value |
|---|---|
| **Name** | `mark_pending` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`, `source_path` = `@item().source_path`, `source_modified_ts` = `@item().source_modified_ts`, `raw_blob_uri` = `@concat('https://<storage-account>.blob.core.windows.net/raw/', item().file_id, '/', last(split(item().source_path, '/')))`, `chunks_prefix` = `@concat(item().file_id, '/')`, `byte_size` = `@item().byte_size`, `ingest_run_id` = `@pipeline().RunId`, `status` = `pending` |

### F8.6 Activity [2c] — OCR + chunk + upload (Notebook)

This activity is where Document Intelligence is called. Because DI is invoked from a notebook via the `azure-ai-documentintelligence` SDK + `DefaultAzureCredential`, there is **no Web activity and no Until polling** in the pipeline at all — the SDK's long-running-operation poller handles waiting for OCR to finish.

**Add activity → Notebook** after `mark_pending`.

| Field | Value |
|---|---|
| **Name** | `ocr_chunk_upload` |
| **Notebook** | `nb_ocr_chunk_upload` |
| **Base parameters** | `file_id` = `@item().file_id`<br/>`raw_blob_uri` = `@concat('https://<storage-account>.blob.core.windows.net/raw/', item().file_id, '/', last(split(item().source_path, '/')))`<br/>`chunks_account` = `<storage-account>`<br/>`chunks_container` = `chunks`<br/>`chunks_prefix` = `@concat(item().file_id, '/')`<br/>`di_endpoint` = `<di-endpoint>` (e.g. `https://di-rag-demo-eus.cognitiveservices.azure.com`) |

The notebook returns `{"chunk_count": N}` as its exit value. The next activity parses it with `@json(activity('ocr_chunk_upload').output.result.exitValue).chunk_count`.

> **Why the raw_blob_uri expression is repeated.** Setting a pipeline variable inside a parallel ForEach is unsafe (variables are pipeline-global, not iteration-scoped). Inlining the expression makes each iteration self-contained.

### F8.7 Activity [2d] — Update control table (succeeded)

**Add activity → Notebook** after `ocr_chunk_upload`.

| Field | Value |
|---|---|
| **Name** | `mark_succeeded` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`, `ingest_run_id` = `@pipeline().RunId`, `chunk_count` = `@json(activity('ocr_chunk_upload').output.result.exitValue).chunk_count`, `status` = `succeeded` |

### F8.8 On-failure handler

On the **red (failure) arrow** of any of [2a] / [2c], add a final **Notebook** activity `mark_failed`:

| Field | Value |
|---|---|
| **Name** | `mark_failed` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`, `ingest_run_id` = `@pipeline().RunId`, `status` = `failed`, `last_error` = `@string(activity('<the-failing-activity>').error)` |

> For simplicity in the demo, attach `mark_failed` only to the `ocr_chunk_upload` failure arrow — that's the most common failure point (DI quota / DI auth / chunk upload). Production builds attach failure handlers to every step.

---

## Phase F9 — Validate end-to-end

### F9.1 Sample run

1. Open the pipeline `pl_ingest_docs` → **Save** → **Run**
2. Watch the **Output** tab as each activity completes:
   - `lookup_new_files` → succeeded, returns `{"new_count": N}` in `exitValue`
   - `lookup_new_files_rows` → succeeded, row count = N
   - `foreach_new_file` → enters ForEach scope
   - For each iteration: `copy_raw_to_blob` → `mark_pending` → `ocr_chunk_upload` → `mark_succeeded` all succeed
3. Most of each iteration's runtime is `ocr_chunk_upload` (Spark session startup + DI OCR + chunking + Blob upload). Typical: **30–90 seconds per file**; **3–8 minutes** total for 5 files with ForEach `Batch count = 4`.

### F9.2 Confirm outputs

```sql
-- SQL analytics endpoint of lh_rag_<env>
SELECT file_id, ocr_status, chunk_status, chunk_count, last_error
FROM control_table_files
ORDER BY ingest_ts DESC;
```

Expected:

- One row per source file
- `ocr_status = 'succeeded'` and `chunk_status = 'succeeded'`
- `chunk_count > 0`
- `last_error IS NULL`

In Azure portal → Storage account → containers:

- `raw/` has subfolders `<file_id>/<original_filename>`
- `chunks/` has subfolders `<file_id>/<file_id>-NNNN.json`

Open one chunk JSON and verify it has `id`, `doc_id`, `chunk_id`, `content`, `source_uri`, `page_start`, `page_end`, `ingest_ts`, `metadata`.

### F9.3 Idempotency

Re-run the pipeline with no source changes. Expected:

- `lookup_new_files` returns `new_count = 0`
- ForEach iterates zero times
- Pipeline succeeds in seconds
- Zero new rows in `control_table_files`, zero new blob writes

If the second run re-processes files, your `file_id` hash isn't stable. See [06-troubleshooting.md § 3.4](./06-troubleshooting.md#34-pipeline-runs-duplicate-files).

### F9.4 Hand off to AI Search

The AI Search indexer (Bicep- or manually-created, see [03-deployment-manual.md § Phase 4](./03-deployment-manual.md#phase-4--ai-search-index) or [04-deployment-automated.md § Step 4](./04-deployment-automated.md)) polls `chunks/` every 5 minutes. Within ~5 min of pipeline completion, the chunks should appear in the search index. Confirm:

```bash
GET https://<search-svc>.search.windows.net/indexers/ixr-chunks/status?api-version=2024-07-01
# Expected: lastResult.status = "success", itemsProcessed > 0
```

---

## Phase F10 — Schedule the pipeline

For demo, leave on manual trigger. For ongoing operation:

1. Open `pl_ingest_docs` → **Schedule**
2. **Status:** On
3. **Repeat:** Every 30 minutes (production batch) or every 5 minutes (low-latency demo, watch capacity cost)
4. **Apply**

Record the pipeline GUID in `demo-ids.local.json` under `fabric.pipelineId`.

> **High concurrency mode for multiple notebooks.** Each `ocr_chunk_upload` invocation spins up a Spark session by default (~30–60 s cold start). For pipelines that process many files, enable **High concurrency mode for pipeline running multiple notebooks** in the workspace settings so notebooks can share a session. See [Notebook activity — Configure notebook settings](https://learn.microsoft.com/fabric/data-factory/notebook-activity#configure-notebook-settings).

---

## Validation checklist

- [ ] Tenant settings F0.1 confirmed by Fabric admin
- [ ] Capacity assigned to workspace (F-SKU, not trial in prod)
- [ ] Workspace identity created and Active
- [ ] Workspace identity granted **Storage Blob Data Contributor** on the storage account
- [ ] Workspace identity granted **Cognitive Services User** on the Document Intelligence resource
- [ ] Lakehouse `lh_rag_<env>` created with `control_table_files` table
- [ ] OneLake shortcut at `Files/source_docs/` showing source documents
- [ ] Blob connection `blob-rag-<env>` created and tested
- [ ] Three notebooks (`nb_lookup_new_files`, `nb_ocr_chunk_upload`, `nb_update_control_table`) saved and runnable manually with sample parameter values
- [ ] Pipeline `pl_ingest_docs` runs end-to-end on sample documents
- [ ] Control table populated; `raw/` and `chunks/` containers populated
- [ ] AI Search indexer picks up new chunks within 5 min
- [ ] Re-running the pipeline is a no-op (idempotency proved — ForEach iterates zero times)

When all boxes are checked → return to [00-reproduce-this-demo.md § Part D](./00-reproduce-this-demo.md#part-d--build-the-copilot-studio-agent-manual--both-paths) to build the Copilot Studio agent.

---

## Troubleshooting pointers

Common Fabric-layer issues are catalogued in [06-troubleshooting.md](./06-troubleshooting.md):

- **OneLake shortcut shows no files / can't be read** → [§ 2](./06-troubleshooting.md#2--onelake--source-attachment)
- **`copy_raw_to_blob` fails with `PathNotFound` and an `abfss:/...` URI in the path** → [§ 3.5](./06-troubleshooting.md#35-copy-activity-fails-with-pathnotfound-and-an-abfss-uri-in-the-path) — `nb_lookup_new_files` is writing absolute abfss URIs instead of paths relative to `Files/`
- **`nb_ocr_chunk_upload` 401/403 from Document Intelligence** → workspace identity missing **Cognitive Services User** on the DI resource ([F2.1](#f21-grant-the-workspace-identity-the-required-roles)) or 15-min RBAC propagation lag ([§ 1.1](./06-troubleshooting.md#11-rbac-propagation-lag))
- **`nb_ocr_chunk_upload` import errors** → the `%pip install` cell didn't run (or ran against the wrong session). See [§ 3.2](./06-troubleshooting.md#32-chunking-notebook-fails)
- **Control table never updates** → [§ 3.3](./06-troubleshooting.md#33-control-table-stuck)
- **Same files re-processed every run** → [§ 3.4](./06-troubleshooting.md#34-pipeline-runs-duplicate-files)
- **Fabric capacity cost spike** → [§ 6.1](./06-troubleshooting.md#61-fabric-capacity-cost-spike) (consider enabling High concurrency mode for the pipeline; see [F10](#phase-f10--schedule-the-pipeline))
- **Workspace identity Blob writes 403** → [§ 1.1 RBAC propagation lag](./06-troubleshooting.md#11-rbac-propagation-lag)
- **"Activity of type 'Until' is not supported inside a 'ForEach' activity"** → this pattern deliberately uses no `Until` activity at all. If you've added one and hit this error, fold the polled operation into a Fabric notebook instead (as `nb_ocr_chunk_upload` does for Document Intelligence). Reference: [ForEach activity limitations](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds).

---

## Reference documentation

Authoritative Microsoft Learn pages this guide tracks (verified against current Microsoft Learn at publication):

**Fabric tenant + workspace + identity**

- [About tenant settings](https://learn.microsoft.com/fabric/admin/about-tenant-settings)
- [Tenant settings index](https://learn.microsoft.com/fabric/admin/tenant-settings-index)
- [Microsoft Fabric workspace identity](https://learn.microsoft.com/fabric/security/workspace-identity)
- [Trusted workspace access](https://learn.microsoft.com/fabric/security/security-trusted-workspace-access)
- [Buy a Microsoft Fabric subscription](https://learn.microsoft.com/fabric/enterprise/buy-subscription)
- [Plan your capacity size](https://learn.microsoft.com/fabric/enterprise/plan-capacity)

**Lakehouse + OneLake**

- [What is a lakehouse in Microsoft Fabric?](https://learn.microsoft.com/fabric/data-engineering/lakehouse-overview)
- [Create an internal OneLake shortcut](https://learn.microsoft.com/fabric/onelake/create-onelake-shortcut)
- [Create an ADLS Gen2 shortcut](https://learn.microsoft.com/fabric/onelake/create-adls-shortcut)
- [Create an Amazon S3 shortcut](https://learn.microsoft.com/fabric/onelake/create-s3-shortcut)

**Data pipeline + activities**

- [Connector overview (supported connectors)](https://learn.microsoft.com/fabric/data-factory/connector-overview)
- [Set up your Azure Blob Storage connection](https://learn.microsoft.com/fabric/data-factory/connector-azure-blob-storage)
- [Configure Lakehouse in a copy activity](https://learn.microsoft.com/fabric/data-factory/connector-lakehouse-copy-activity)
- [Transform data by running a notebook (Notebook activity)](https://learn.microsoft.com/fabric/data-factory/notebook-activity)
- [Notebook activity high-concurrency mode for pipelines](https://learn.microsoft.com/fabric/data-factory/notebook-activity#configure-notebook-settings)
- [Web activity (Fabric) — connection-based, no inline MI/Resource fields](https://learn.microsoft.com/fabric/data-factory/web-activity)
- [Web v2 connector — auth supported in Dataflow Gen2 only, not pipelines](https://learn.microsoft.com/fabric/data-factory/connector-web-overview)
- [ADF/Fabric REST connector parity (no system-assigned MI in Fabric REST)](https://learn.microsoft.com/fabric/data-factory/connector-parity)
- [ForEach activity limitations and workarounds (ADF — applies to Fabric pipelines)](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds)
- [Nested activities in ADF / Fabric — embedding limitations](https://learn.microsoft.com/azure/data-factory/concepts-nested-activities#nested-activity-embedding-limitations)
- [Configure Azure Key Vault references (connection credentials)](https://learn.microsoft.com/fabric/data-factory/azure-key-vault-reference-configure)

**Notebook utilities**

- [NotebookUtils (former MSSparkUtils) for Fabric](https://learn.microsoft.com/fabric/data-engineering/notebook-utilities)
- [NotebookUtils notebook run and orchestration](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-notebook-run)

**Document Intelligence**

- [Azure AI Document Intelligence Python SDK (`azure-ai-documentintelligence`) reference](https://learn.microsoft.com/python/api/overview/azure/ai-documentintelligence-readme)
- [Document Intelligence prebuilt-read model](https://learn.microsoft.com/azure/ai-services/document-intelligence/prebuilt/read)
- [Managed identities for Document Intelligence](https://learn.microsoft.com/azure/ai-services/document-intelligence/authentication/managed-identities?view=doc-intel-4.0.0)

---

*Last updated: 2026-05-22*

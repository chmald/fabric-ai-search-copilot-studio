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
│   ├── nb_lookup_new_files       ← called from parent pipeline activity [1]
│   ├── nb_chunk_and_upload       ← called from child pipeline activity [C5]
│   └── nb_update_control_table   ← called from child pipeline activities [C2], [C6], on-error
├── Parent pipeline: pl_ingest_docs
│   ├── [1]  Notebook activity     → nb_lookup_new_files (writes _tmp_new_files)
│   ├── [1′] Lookup activity       → read _tmp_new_files rows for the ForEach
│   └── [2]  ForEach over Lookup output:
│       └── [2a] Invoke pipeline    → pl_process_file (one invocation per source file)
└── Child pipeline:  pl_process_file (parameters per file)
    ├── [C1] Copy data             → OneLake source → Blob raw/    (workspace-identity auth)
    ├── [C2] Notebook              → nb_update_control_table (status=pending)
    ├── [C3] Web activity          → Document Intelligence analyze (workspace-identity auth)
    ├── [C4] Until + Web           → poll operation-location until status=succeeded
    ├── [C5] Notebook              → nb_chunk_and_upload (writes chunks/ JSON)
    ├── [C6] Notebook              → nb_update_control_table (status=succeeded)
    └── On-error handler           → nb_update_control_table (status=failed, last_error)
```

> **Why two pipelines?** Fabric Data Factory pipelines (like Azure Data Factory) do **not** allow nesting an `Until` activity inside a `ForEach` activity (or vice versa). The documented workaround is the **two-level pipeline pattern**: the parent pipeline iterates with `ForEach`, and each iteration calls a child pipeline that contains the `Until` loop. See [ForEach activity limitations and workarounds](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds) and [Nested activity embedding limitations](https://learn.microsoft.com/azure/data-factory/concepts-nested-activities#nested-activity-embedding-limitations). The child pipeline is invoked via the Fabric **Invoke pipeline activity** — see [Use the Invoke pipeline activity](https://learn.microsoft.com/fabric/data-factory/invoke-pipeline-activity).
>
> **Bonus benefit.** Pipeline variables are global to a pipeline run — a parallel `ForEach` would race on shared variables like `raw_blob_uri`. Splitting the per-file work into a child pipeline gives each invocation its own variable scope automatically.

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

# 2. Call Document Intelligence prebuilt-read with a bearer token
#    (Web activity uses Authentication = System Assigned Managed Identity →
#     Resource = https://cognitiveservices.azure.com/)
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

Fabric pipelines authenticate to external services through **connections**. For this pattern you only need to pre-create **one connection** — Azure Blob Storage — for the Copy activity. Document Intelligence is called by a Web activity whose built-in authentication kind is **System Assigned Managed Identity** (Fabric resolves this to the workspace identity), so no DI connection or Key Vault reference is needed.

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
from pyspark.sql.functions import col, md5, concat_ws

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

### F7.2 `nb_chunk_and_upload`

Parameters expected:

- `file_id` (string)
- `di_result_json` (string — JSON-serialized Document Intelligence response)
- `raw_blob_uri` (string)
- `chunks_account` (string)
- `chunks_container` (string)  — `chunks`
- `chunks_prefix` (string) — typically `f"{file_id}/"`

```python
# Parameters (overridden by pipeline)
file_id          = ""
di_result_json   = "{}"
raw_blob_uri     = ""
chunks_account   = ""
chunks_container = "chunks"
chunks_prefix    = ""

# Install required packages (cached in the session after first install)
%pip install tiktoken==0.7.0 azure-storage-blob==12.21.0 azure-identity==1.17.0 --quiet
```

```python
import json
import tiktoken
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

# Chunking knobs — adjust per corpus
CHUNK_TOKENS    = 1000
OVERLAP_TOKENS  = 200
ENCODING        = tiktoken.encoding_for_model("gpt-4o")

di_result = json.loads(di_result_json)

def chunk_pages(pages, max_tok=CHUNK_TOKENS, overlap=OVERLAP_TOKENS):
    """Page-aware chunker with token budget + overlap. Never splits mid-page."""
    chunks = []
    buf, buf_pages, buf_tok = [], [], 0
    for page in pages:
        page_text = page["content"]
        page_no   = page["pageNumber"]
        page_tok  = len(ENCODING.encode(page_text))
        if buf_tok + page_tok > max_tok and buf:
            chunks.append({"text": "\n\n".join(buf), "pages": buf_pages})
            # carry the last page forward as overlap
            buf       = [buf[-1]] if overlap > 0 else []
            buf_pages = [buf_pages[-1]] if overlap > 0 else []
            buf_tok   = len(ENCODING.encode(buf[0])) if buf else 0
        buf.append(page_text)
        buf_pages.append(page_no)
        buf_tok += page_tok
    if buf:
        chunks.append({"text": "\n\n".join(buf), "pages": buf_pages})
    return chunks

# Flatten DI pages to (pageNumber, content)
raw_pages = di_result.get("analyzeResult", {}).get("pages", [])
flat_pages = [
    {
        "pageNumber": p["pageNumber"],
        "content": " ".join(line["content"] for line in p.get("lines", [])),
    }
    for p in raw_pages
]

chunks = chunk_pages(flat_pages)

# Upload one JSON per chunk to Blob chunks/<chunks_prefix>
cred = DefaultAzureCredential()
svc  = BlobServiceClient(
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

> **Auth note for `DefaultAzureCredential` inside Fabric notebooks.** When run inside a Fabric notebook activity in a workspace with a workspace identity, `DefaultAzureCredential` resolves to the workspace identity automatically. This is why F2.1 (granting Blob Data Contributor) is the load-bearing step for this notebook to work without keys.

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

## Phase F8 — Build the parent pipeline `pl_ingest_docs`

1. Inside the workspace: **+ New item → Data pipeline** → name `pl_ingest_docs` → **Create**
2. **Add activity → Notebook** (this is activity [1])

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

Inside the ForEach, the **only** activity is a single Invoke pipeline call to the per-file child pipeline:

### F8.4 Activity [2a] — Invoke pipeline (call `pl_process_file`)

> **Why only one activity inside the ForEach?** Fabric pipelines do **not** allow an `Until` activity inside a `ForEach` (see the note in [What you'll build](#what-youll-build)). All per-file work — including the `Until` loop that polls Document Intelligence — lives in the child pipeline `pl_process_file`, which you'll build in [Phase F8b](#phase-f8b--build-the-child-pipeline-pl_process_file).

You'll have to build the child pipeline first (or create an empty `pl_process_file` placeholder now, wire it up here, then come back to fill it in). The order below assumes you create the placeholder first.

1. Inside the ForEach, **Add activity → Invoke pipeline** (the modern one, not "Invoke pipeline (Legacy)" — the modern activity supports cross-workspace calls and per-child run monitoring).
2. **General → Name:** `invoke_process_file`
3. **Settings:**
   - **Type:** `Fabric`
   - **Connection:** create a new connection or reuse one. Pick **Workspace identity** as the authentication kind — the workspace identity needs at least **Contributor** on this workspace to invoke pipelines (assigned automatically when the identity is created in the same workspace). See [Invoke pipeline activity — using Workspace Identity](https://learn.microsoft.com/fabric/data-factory/invoke-pipeline-activity).
   - **Workspace:** `ws-rag-<env>`
   - **Pipeline:** `pl_process_file`
   - **Wait on completion:** **On** (so the parent ForEach reports per-file success/failure correctly)
4. **Parameters** — bind these from the ForEach `@item()` and pipeline-level constants:

| Child parameter | Value expression |
|---|---|
| `file_id` | `@item().file_id` |
| `source_path` | `@item().source_path` |
| `source_modified_ts` | `@item().source_modified_ts` |
| `byte_size` | `@item().byte_size` |
| `ingest_run_id` | `@pipeline().RunId` |
| `storage_account` | `<storage-account>` (constant) |
| `raw_container` | `raw` (constant) |
| `chunks_container` | `chunks` (constant) |
| `di_endpoint` | `<di-endpoint>` (constant, value from `demo-ids.local.json` → `azure.documentIntelligenceEndpoint`) |

The ForEach's parallelism cap (F8.3 `Batch count`) now controls how many child-pipeline runs execute concurrently.

---

## Phase F8b — Build the child pipeline `pl_process_file`

This pipeline runs **once per source file**. It contains the Copy, DI submit, Until polling, chunk-upload, and control-table-update activities that previously lived inside the parent's ForEach.

1. Inside the workspace: **+ New item → Data pipeline** → name `pl_process_file` → **Create**
2. Open the pipeline. In the empty canvas, select the **Parameters** tab (bottom pane) and add the following pipeline parameters — all string type unless noted:

| Name | Type | Notes |
|---|---|---|
| `file_id` | string | |
| `source_path` | string | OneLake source path |
| `source_modified_ts` | string | ISO timestamp passed through to control table |
| `byte_size` | int | |
| `ingest_run_id` | string | parent's `@pipeline().RunId` |
| `storage_account` | string | e.g. `stragdemoeus` |
| `raw_container` | string | `raw` |
| `chunks_container` | string | `chunks` |
| `di_endpoint` | string | e.g. `https://di-rag-demo-eus.cognitiveservices.azure.com` |

Then add a single **variable** for the raw-blob URI:

| Variable | Type | Default value |
|---|---|---|
| `raw_blob_uri` | string | (leave blank) |

Now add the activities:

### F8b.1 Activity [C1] — Copy data (OneLake source → Blob raw/)

**Add activity → Copy data**.

| Field | Value |
|---|---|
| **General → Name** | `copy_raw_to_blob` |
| **Source → Connection** | `lh_rag_<env>` (Lakehouse) |
| **Source → Root folder** | `Files` |
| **Source → File path** | `@pipeline().parameters.source_path` (or the relative path returned by the lookup notebook — see tip below) |
| **Source → File format** | **Binary** (preserves bytes) |
| **Sink → Connection** | `blob-rag-<env>` (from F6.1) |
| **Sink → Container** | `@pipeline().parameters.raw_container` |
| **Sink → File path** | `@concat(pipeline().parameters.file_id, '/', last(split(pipeline().parameters.source_path, '/')))` |
| **Sink → File format** | **Binary** |

> **Tip.** The simplest way to set source File path correctly is to use the **Browse** picker in the Copy activity UI on a sample file, then templatize with `@pipeline().parameters.source_path`. The exact path syntax depends on whether your Lakehouse uses schemas — verify against [Configure Lakehouse in a copy activity](https://learn.microsoft.com/fabric/data-factory/connector-lakehouse-copy-activity).

### F8b.2 Activity [C1.5] — Set raw_blob_uri (Set variable)

Immediately after the Copy succeeds, add a **Set variable** activity:

| Field | Value |
|---|---|
| **General → Name** | `set_raw_blob_uri` |
| **Variable name** | `raw_blob_uri` |
| **Value** | `@concat('https://', pipeline().parameters.storage_account, '.blob.core.windows.net/', pipeline().parameters.raw_container, '/', pipeline().parameters.file_id, '/', last(split(pipeline().parameters.source_path, '/')))` |

> Setting a variable inside a child pipeline is safe (no cross-iteration races) because each Invoke-pipeline call is a separate pipeline run with its own variable scope — this is the second reason for the two-pipeline split.

### F8b.3 Activity [C2] — Update control table (pending)

**Add activity → Notebook** after `set_raw_blob_uri`.

| Field | Value |
|---|---|
| **Name** | `mark_pending` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@pipeline().parameters.file_id`, `source_path` = `@pipeline().parameters.source_path`, `source_modified_ts` = `@pipeline().parameters.source_modified_ts`, `raw_blob_uri` = `@variables('raw_blob_uri')`, `chunks_prefix` = `@concat(pipeline().parameters.file_id, '/')`, `byte_size` = `@pipeline().parameters.byte_size`, `ingest_run_id` = `@pipeline().parameters.ingest_run_id`, `status` = `pending` |

### F8b.4 Activity [C3] — Call Document Intelligence (async submit)

With API keys disabled on Document Intelligence, the Web activity authenticates with **System Assigned Managed Identity** — in Fabric this resolves to the workspace identity, which has **Cognitive Services User** on the DI resource thanks to [F2.1](#f21-grant-the-workspace-identity-the-required-roles).

**Add activity → Web** after `mark_pending`.

Reference: [Web activity (Fabric)](https://learn.microsoft.com/fabric/data-factory/web-activity) and [Document Intelligence REST API quickstart](https://learn.microsoft.com/azure/ai-services/document-intelligence/quickstarts/get-started-sdks-rest-api?view=doc-intel-4.0.0&pivots=programming-language-rest-api).

| Field | Value |
|---|---|
| **Name** | `di_analyze_submit` |
| **URL** | `@concat(pipeline().parameters.di_endpoint, '/documentintelligence/documentModels/prebuilt-read:analyze?api-version=2024-11-30')` |
| **Method** | `POST` |
| **Headers** | `Content-Type` = `application/json` |
| **Body** | `{"urlSource": "@{variables('raw_blob_uri')}"}` |
| **Authentication** | **System Assigned Managed Identity** |
| **Resource** | `https://cognitiveservices.azure.com/` |
| **Advanced → Secure input** | **On** (defence-in-depth even though there's no secret in the body) |

The Document Intelligence `analyze` endpoint is **async**: the successful response is HTTP **202 Accepted** with an `Operation-Location` header containing the URL to poll. Capture it for the next step — expression: `@activity('di_analyze_submit').output.ADFWebActivityResponseHeaders['Operation-Location']` (header name case varies; `operation-location` is also valid).

> **Note on `urlSource` access.** The `urlSource` URL is fetched server-side by Document Intelligence. Because shared-key access on the storage account is disabled and SAS tokens are not used by this pattern, **DI must authenticate to Blob with its own managed identity**. The Bicep `rbac.bicep` module grants DI's system-assigned MI **Storage Blob Data Reader** on the storage account automatically; if you provisioned manually, see [03-deployment-manual.md § 1.7 step 3](./03-deployment-manual.md#17-rbac-wiring) and [Managed identities for Document Intelligence](https://learn.microsoft.com/azure/ai-services/document-intelligence/authentication/managed-identities?view=doc-intel-4.0.0).

### F8b.5 Activity [C4] — Until + Web (poll DI result)

The DI `analyze` op returns immediately with `Operation-Location`; you must poll it until `status = succeeded` (or `failed`). This is the **reason this pipeline exists** — the Until activity cannot live inside the parent's ForEach, but inside this single-run child pipeline it has no nesting conflicts.

1. **Add activity → Until** after `di_analyze_submit`. Name it `poll_di_result`.
2. **Settings → Expression:** `@or(equals(activity('di_get_result').output.status, 'succeeded'), equals(activity('di_get_result').output.status, 'failed'))`
3. **Settings → Timeout:** `0.00:05:00` (5 minutes — increase for large files)
4. Inside the Until, add:
   - **Wait** activity `wait_2s` → 2 seconds
   - **Web** activity `di_get_result`:
     - **URL:** `@activity('di_analyze_submit').output.ADFWebActivityResponseHeaders['Operation-Location']`
     - **Method:** `GET`
     - **Authentication:** **System Assigned Managed Identity**
     - **Resource:** `https://cognitiveservices.azure.com/`
     - **Advanced → Secure input:** **On**

After the Until exits, the latest `di_get_result` output contains the full DI response under `.analyzeResult`. JSON-serialize it for the next step:

- Pipeline expression: `@string(activity('di_get_result').output)` → bind to the `di_result_json` parameter of the chunk notebook.

### F8b.6 Activity [C5] — Chunk + upload

**Add activity → Notebook** after `poll_di_result`.

| Field | Value |
|---|---|
| **Name** | `chunk_and_upload` |
| **Notebook** | `nb_chunk_and_upload` |
| **Base parameters** | `file_id` = `@pipeline().parameters.file_id`<br/>`di_result_json` = `@string(activity('di_get_result').output)`<br/>`raw_blob_uri` = `@variables('raw_blob_uri')`<br/>`chunks_account` = `@pipeline().parameters.storage_account`<br/>`chunks_container` = `@pipeline().parameters.chunks_container`<br/>`chunks_prefix` = `@concat(pipeline().parameters.file_id, '/')` |

Capture the returned `chunk_count` for use in the next activity. The notebook exit value is a JSON string, so parse it:

`@json(activity('chunk_and_upload').output.result.exitValue).chunk_count`

### F8b.7 Activity [C6] — Update control table (succeeded)

**Add activity → Notebook** after `chunk_and_upload`.

| Field | Value |
|---|---|
| **Name** | `mark_succeeded` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@pipeline().parameters.file_id`, `ingest_run_id` = `@pipeline().parameters.ingest_run_id`, `chunk_count` = `@json(activity('chunk_and_upload').output.result.exitValue).chunk_count`, `status` = `succeeded` |

### F8b.8 On-failure handler

On the **red (failure) arrow** of any of [C1] / [C3] / [C4] / [C5], add a final **Notebook** activity `mark_failed`:

| Field | Value |
|---|---|
| **Name** | `mark_failed` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@pipeline().parameters.file_id`, `ingest_run_id` = `@pipeline().parameters.ingest_run_id`, `status` = `failed`, `last_error` = `@string(activity('<the-failing-activity>').error)` |

> For simplicity in the demo, attach `mark_failed` only to the `chunk_and_upload` failure arrow — that's the most common failure point. Production builds attach failure handlers to every step. Because this is a child pipeline, the failure handler runs once per failing file rather than once per pipeline run.

Because `mark_failed` is the last activity on a failure path, the child pipeline as a whole still reports a `Failed` status to the parent's Invoke-pipeline activity. That bubble-up is what makes the parent's ForEach iteration accurately reflect per-file success/failure in monitoring.

---

## Phase F9 — Validate end-to-end

### F9.1 Sample run

1. Open the parent pipeline `pl_ingest_docs` → **Save** → **Run**
2. Watch the **Output** tab of the parent run as each activity completes:
   - `lookup_new_files` → succeeded, returns `{"new_count": N}` in `exitValue`
   - `lookup_new_files_rows` → succeeded, row count = N
   - `foreach_new_file` → enters ForEach scope
   - For each iteration: `invoke_process_file` → spawns one `pl_process_file` run
3. Click into any `invoke_process_file` activity to drill down into its child run, or open the workspace **Monitor** view and filter by pipeline = `pl_process_file`. In each child run the activities should complete in order: `copy_raw_to_blob` → `set_raw_blob_uri` → `mark_pending` → `di_analyze_submit` → `poll_di_result` (Until loop, typically 5–20 iterations) → `chunk_and_upload` → `mark_succeeded`.
4. Total runtime for 5 sample files: typically **3–8 minutes** (DI OCR is the dominant cost). Parallelism between files is governed by the parent ForEach's `Batch count`.

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

1. Open the **parent** pipeline `pl_ingest_docs` → **Schedule**
2. **Status:** On
3. **Repeat:** Every 30 minutes (production batch) or every 5 minutes (low-latency demo, watch capacity cost)
4. **Apply**

> **Only schedule the parent.** Child pipelines like `pl_process_file` are invoked on demand by the parent's ForEach — they must **not** have their own schedule (a stand-alone child run would have no `file_id` parameter and would fail immediately).

Record both pipeline GUIDs in `demo-ids.local.json` under `fabric.parentPipelineId` (`pl_ingest_docs`) and `fabric.childPipelineId` (`pl_process_file`).

---

## Validation checklist

- [ ] Tenant settings F0.1 confirmed by Fabric admin
- [ ] Capacity assigned to workspace (F-SKU, not trial in prod)
- [ ] Workspace identity created and Active
- [ ] Workspace identity granted **Storage Blob Data Contributor** on the storage account
- [ ] Workspace identity granted **Cognitive Services User** on the Document Intelligence resource
- [ ] Workspace identity has at least **Contributor** on the Fabric workspace (default for identities created in the same workspace; required for the parent's Invoke-pipeline activity)
- [ ] Lakehouse `lh_rag_<env>` created with `control_table_files` table
- [ ] OneLake shortcut at `Files/source_docs/` showing source documents
- [ ] Blob connection `blob-rag-<env>` created and tested
- [ ] Three notebooks (`nb_lookup_new_files`, `nb_chunk_and_upload`, `nb_update_control_table`) saved
- [ ] Child pipeline `pl_process_file` has all 9 pipeline parameters declared and runs successfully when invoked manually with sample parameter values
- [ ] Parent pipeline `pl_ingest_docs` runs end-to-end and spawns one `pl_process_file` child run per source file
- [ ] Control table populated; `raw/` and `chunks/` containers populated
- [ ] AI Search indexer picks up new chunks within 5 min
- [ ] Re-running the parent pipeline is a no-op (idempotency proved — no child runs spawned)
- [ ] Only `pl_ingest_docs` has a schedule — `pl_process_file` is left on "on demand" trigger only

When all boxes are checked → return to [00-reproduce-this-demo.md § Part D](./00-reproduce-this-demo.md#part-d--build-the-copilot-studio-agent-manual--both-paths) to build the Copilot Studio agent.

---

## Troubleshooting pointers

Common Fabric-layer issues are catalogued in [06-troubleshooting.md](./06-troubleshooting.md):

- **OneLake shortcut shows no files / can't be read** → [§ 2](./06-troubleshooting.md#2--onelake--source-attachment)
- **Pipeline Web activity → DI fails (401/403/404/500)** → [§ 3.1](./06-troubleshooting.md#31-document-intelligence-call-fails)
- **Chunking notebook fails on imports** → [§ 3.2](./06-troubleshooting.md#32-chunking-notebook-fails)
- **Control table never updates** → [§ 3.3](./06-troubleshooting.md#33-control-table-stuck)
- **Same files re-processed every run** → [§ 3.4](./06-troubleshooting.md#34-pipeline-runs-duplicate-files)
- **Fabric capacity cost spike** → [§ 6.1](./06-troubleshooting.md#61-fabric-capacity-cost-spike)
- **Workspace identity Blob writes 403** → [§ 1.1 RBAC propagation lag](./06-troubleshooting.md#11-rbac-propagation-lag)
- **"Activity of type 'Until' is not supported inside a 'ForEach' activity"** → you tried to nest Until inside ForEach. This is a fundamental Fabric / ADF limitation; the workaround is to move the Until-bearing block into a child pipeline and invoke it from the ForEach. This pattern already implements that split — [F8.4](#f84-activity-2a--invoke-pipeline-call-pl_process_file) + [Phase F8b](#phase-f8b--build-the-child-pipeline-pl_process_file). Reference: [ForEach activity limitations](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds).

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
- [Web activity for REST API calls](https://learn.microsoft.com/fabric/data-factory/web-activity)
- [Transform data by running a notebook (Notebook activity)](https://learn.microsoft.com/fabric/data-factory/notebook-activity)
- [Use the Until activity to control execution flow](https://learn.microsoft.com/fabric/data-factory/until-activity)
- [Use the Invoke pipeline activity to run another pipeline](https://learn.microsoft.com/fabric/data-factory/invoke-pipeline-activity)
- [ForEach activity limitations and workarounds (ADF — applies to Fabric pipelines)](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds)
- [Nested activities in ADF / Fabric — embedding limitations](https://learn.microsoft.com/azure/data-factory/concepts-nested-activities#nested-activity-embedding-limitations)
- [Configure Azure Key Vault references (connection credentials)](https://learn.microsoft.com/fabric/data-factory/azure-key-vault-reference-configure)
- [Use Azure Key Vault secrets in pipeline activities (Web activity pattern)](https://learn.microsoft.com/azure/data-factory/how-to-use-azure-key-vault-secrets-pipeline-activities)

**Notebook utilities**

- [NotebookUtils (former MSSparkUtils) for Fabric](https://learn.microsoft.com/fabric/data-engineering/notebook-utilities)
- [NotebookUtils notebook run and orchestration](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-notebook-run)

**Document Intelligence**

- [Document Intelligence REST API quickstart](https://learn.microsoft.com/azure/ai-services/document-intelligence/quickstarts/get-started-sdks-rest-api?view=doc-intel-4.0.0&pivots=programming-language-rest-api)
- [Document Intelligence prebuilt-read model](https://learn.microsoft.com/azure/ai-services/document-intelligence/prebuilt/read)
- [Managed identities for Document Intelligence](https://learn.microsoft.com/azure/ai-services/document-intelligence/authentication/managed-identities?view=doc-intel-4.0.0)

---

*Last updated: 2026-05-22*

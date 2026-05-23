# 03b — Fabric setup (manual — both deployment paths)

The Fabric layer of this pattern is **always manual**. Neither the manual Azure path ([03-deployment-manual.md](./03-deployment-manual.md)) nor the Bicep-automated path ([04-deployment-automated.md](./04-deployment-automated.md)) can provision Fabric items today — Fabric workspaces, Lakehouses, OneLake shortcuts, and Data Pipelines have no Bicep/ARM resource provider as of this pattern's publication, and the [Fabric REST APIs](https://learn.microsoft.com/en-us/rest/api/fabric/articles/) for items are only partially covered for automation.

> **Run this doc after Azure platform layer is up.** You need the Azure resources from [03-deployment-manual.md § Phase 1](./03-deployment-manual.md#phase-1--foundation) (manual) **or** the deployment outputs from [04-deployment-automated.md § Step 3](./04-deployment-automated.md) (automated) before you can wire the Fabric pipeline to them. Specifically you need: the storage account name, the Document Intelligence endpoint, and a Key Vault that holds the DI key.

> **Time budget.** First-time Fabric build: **2–3 hours** end-to-end. Subsequent rebuilds in the same tenant: **45–60 minutes** once the workspace identity, connections, and notebook artifacts can be reused.

---

## What you'll build

```
Fabric workspace (ws-rag-<env>)
├── Workspace identity (auto-created service principal, used for Blob auth)
├── Connections
│   ├── Azure Key Vault connection (reads DI key at pipeline runtime)
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
│   ├── nb_chunk_and_upload       ← called from pipeline activity [2d]
│   └── nb_update_control_table   ← called from pipeline activities [2b] and [2e]
└── Data Pipeline: pl_ingest_docs
    ├── [1] Notebook activity     → nb_lookup_new_files
    ├── [2] ForEach (over _tmp_new_files):
    │   ├── [2a] Copy data        → OneLake source → Blob raw/
    │   ├── [2b] Notebook         → nb_update_control_table (status=pending)
    │   ├── [2c] Web activity     → Document Intelligence analyze (async submit)
    │   ├── [2c'] Until + Web     → poll operation-location until status=succeeded
    │   ├── [2d] Notebook         → nb_chunk_and_upload (writes chunks/ JSON)
    │   └── [2e] Notebook         → nb_update_control_table (status=succeeded)
    └── On-error handler          → nb_update_control_table (status=failed, last_error)
```

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

Trial capacity (60-day) is acceptable for an initial build, but plan to move to an F-SKU before the demo for SLA reasons. See [Microsoft Fabric concepts — Capacity](https://learn.microsoft.com/en-us/fabric/enterprise/licenses#capacity).

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

### F2.1 Grant the workspace identity Blob Data Contributor

The pipeline writes raw files to `raw/` and chunk JSON to `chunks/`. The identity needs **write** access on both.

From the **Azure portal** (or `az cli` — both shown):

```bash
ST_RES_ID=$(az storage account show --name <storage-account> -g <rg> --query id -o tsv)
# Find the workspace identity object ID — easiest via Azure portal:
#   Microsoft Entra ID → Enterprise applications → search for the workspace name → Object ID
WS_OBJID=<workspace-identity-object-id>

az role assignment create \
  --assignee-object-id $WS_OBJID --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" \
  --scope $ST_RES_ID
```

> **Propagation:** Azure role assignments to Fabric workspace identities can take up to **15 minutes** to be honored end-to-end (Fabric token cache + Azure RBAC cache). If your first pipeline run fails with `403 Forbidden`, wait and retry before debugging further.

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

## Phase F6 — Create connections (Key Vault + Blob)

Fabric pipelines authenticate to external services through **connections**. You need two for this pattern: a Key Vault connection (to read the Document Intelligence key at pipeline runtime) and a Blob Storage connection (for the Copy activity).

Reference: [Set up connections for Fabric pipelines](https://learn.microsoft.com/en-us/fabric/data-factory/connectors-overview).

### F6.1 Azure Key Vault connection (for the DI subscription key)

The Document Intelligence REST API is keyed (the `Ocp-Apim-Subscription-Key` header). Pull that key from Key Vault at runtime — never embed it in the pipeline.

1. **Fabric portal → top-right gear icon → Manage connections and gateways → Connections → + New**
2. **Connection type:** **Azure Key Vault**
3. **Server URL:** `https://<your-keyvault-name>.vault.azure.net/` (note the trailing slash)
4. **Authentication kind:**
   - **Service principal** — recommended; create a dedicated SP and grant it **Key Vault Secrets User** on the vault, OR
   - **Organizational account** — works for demo, but pipeline-time auth follows the user's session
5. **Connection name:** `kv-rag-<env>`
6. **Create** → test the connection (Fabric will validate it can list secrets)

In Azure portal, grant whichever principal you chose **Key Vault Secrets User** (data-plane read) on the vault:

```bash
KV_RES_ID=$(az keyvault show --name <kv-name> --query id -o tsv)
az role assignment create \
  --assignee-object-id <sp-or-user-object-id> --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope $KV_RES_ID
```

### F6.2 Azure Blob Storage connection (for Copy activity to raw/)

1. **Connections → + New**
2. **Connection type:** **Azure Blob Storage**
3. **Account name or URL:** `https://<storage-account>.blob.core.windows.net`
4. **Authentication kind:** **Organizational account** (uses the workspace identity if available — Fabric automatically prefers workspace identity for pipeline activities in identity-enabled workspaces) — or **Service principal** if you prefer explicit SP auth
5. **Connection name:** `blob-rag-<env>`
6. **Create**

Reference: [Set up your Azure Blob Storage connection](https://learn.microsoft.com/en-us/fabric/data-factory/connector-azure-blob-storage).

> The workspace identity already has Storage Blob Data Contributor from Phase F2.1. If you choose Service principal here instead, grant that SP the same role.

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

If this throws `403 Forbidden`, the F2.1 role assignment hasn't propagated yet (wait up to 15 min) or the workspace identity isn't on the role. Re-check `Microsoft Entra ID → Enterprise applications → <workspace name> → Object ID` matches what was granted the role.

Clean up the test path after success:

```python
dbutils.fs.rm(f"abfss://{container}@{blob_account}.dfs.core.windows.net/_test_workspace_identity/", recurse=True)
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

# Persist for the pipeline's ForEach to read
new_files.write.format("delta").mode("overwrite").saveAsTable("_tmp_new_files")

# Return count + collected list as notebook exit value for the pipeline
new_count = new_files.count()
rows = [r.asDict() for r in new_files.collect()]
mssparkutils.notebook.exit({"new_count": new_count, "files": rows})
```

> **`mssparkutils.notebook.exit(...)`** is the Fabric way to return structured data from a notebook activity. The pipeline can then bind `@activity('nb_lookup_new_files').output.result.exitValue.files` directly into a ForEach activity's `items`. See [Notebook activity exit value](https://learn.microsoft.com/en-us/fabric/data-factory/pipeline-notebook-activity).

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

mssparkutils.notebook.exit({"chunk_count": len(chunks)})
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

mssparkutils.notebook.exit({"file_id": file_id, "status": status})
```

---

## Phase F8 — Build the Data Pipeline

1. Inside the workspace: **+ New item → Data pipeline** → name `pl_ingest_docs` → **Create**
2. **Add activity → Notebook** (this is activity [1])

### F8.1 Activity [1] — Lookup new files

| Field | Value |
|---|---|
| **General → Name** | `lookup_new_files` |
| **Settings → Notebook** | `nb_lookup_new_files` |
| **Settings → Base parameters** | `source_path` = `Files/source_docs/` |

### F8.2 Activity [2] — ForEach over new files

Drag a **ForEach** activity onto the canvas after `lookup_new_files`. Connect them with the green (success) arrow.

| Field | Value |
|---|---|
| **General → Name** | `foreach_new_file` |
| **Settings → Items** | `@activity('lookup_new_files').output.result.exitValue.files` |
| **Settings → Sequential** | **Off** for parallelism; cap with **Batch count** = 4 for the demo (raise per capacity headroom) |

Inside the ForEach, add the following five activities in sequence:

### F8.3 Activity [2a] — Copy data (OneLake source → Blob raw/)

Inside the ForEach, **Add activity → Copy data**.

| Field | Value |
|---|---|
| **General → Name** | `copy_raw_to_blob` |
| **Source → Connection** | `lh_rag_<env>` (Lakehouse) |
| **Source → Root folder** | `Files` |
| **Source → File path** | `@replace(item().source_path, concat('abfss://...@onelake.dfs.fabric.microsoft.com/', '<workspaceId>/<lakehouseId>/'), '')` (or simpler: use the relative path Spark returned) |
| **Source → File format** | **Binary** (preserves bytes) |
| **Sink → Connection** | `blob-rag-<env>` (from F6.2) |
| **Sink → Container** | `raw` |
| **Sink → File path** | `@concat(item().file_id, '/', last(split(item().source_path, '/')))` |
| **Sink → File format** | **Binary** |

> **Tip.** The simplest way to set source File path correctly is to use the **Browse** picker in the Copy activity UI on a sample file, then templatize with `@item().source_path`. The exact path syntax depends on whether your Lakehouse uses schemas — verify against [Copy activity Lakehouse source](https://learn.microsoft.com/en-us/fabric/data-factory/lakehouse-source-copy-activity).

After this activity, capture the resulting blob URI into a pipeline variable `raw_blob_uri`:

`@concat('https://<storage-account>.blob.core.windows.net/raw/', item().file_id, '/', last(split(item().source_path, '/')))`

### F8.4 Activity [2b] — Update control table (pending)

**Add activity → Notebook** after the Copy.

| Field | Value |
|---|---|
| **Name** | `mark_pending` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`, `source_path` = `@item().source_path`, `source_modified_ts` = `@item().source_modified_ts`, `raw_blob_uri` = `@variables('raw_blob_uri')`, `chunks_prefix` = `@concat(item().file_id, '/')`, `byte_size` = `@item().byte_size`, `ingest_run_id` = `@pipeline().RunId`, `status` = `pending` |

### F8.5 Activity [2c] — Call Document Intelligence (async submit)

**Add activity → Web** after `mark_pending`.

Reference: [Web activity for REST API calls](https://learn.microsoft.com/en-us/fabric/data-factory/web-activity) and [Document Intelligence analyze REST API](https://learn.microsoft.com/en-us/rest/api/aiservices/document-models/analyze-document).

| Field | Value |
|---|---|
| **Name** | `di_analyze_submit` |
| **URL** | `@concat('<di-endpoint>', '/documentintelligence/documentModels/prebuilt-read:analyze?api-version=2024-11-30')` — replace `<di-endpoint>` with the value from `demo-ids.local.json` (`azure.documentIntelligence` resource's endpoint) |
| **Method** | `POST` |
| **Headers** | `Content-Type` = `application/json`<br/>`Ocp-Apim-Subscription-Key` = **Linked service reference** → `kv-rag-<env>` → secret name `di-key` |
| **Body** | `{"urlSource": "@{variables('raw_blob_uri')}"}` |

For the **Ocp-Apim-Subscription-Key** header, choose **Connection (Azure Key Vault)** in the value picker, point at the `kv-rag-<env>` connection from F6.1, and specify the secret name (`di-key`). Fabric reads the secret at pipeline runtime; the key is never persisted in the pipeline definition.

The Document Intelligence `analyze` endpoint is **async**. The successful response has HTTP **202 Accepted** and an `operation-location` header containing the URL to poll. Capture it:

- Use `@activity('di_analyze_submit').output.ADFWebActivityResponseHeaders['Operation-Location']` (or `operation-location` — header case varies) in the next step.

> **Note on `urlSource` access.** The `urlSource` URL is fetched server-side by Document Intelligence. For a private blob, either (a) sign the URL with a short-lived SAS before passing it here, or (b) grant Document Intelligence's identity Read on the storage account (requires Document Intelligence MI to be enabled — see [Document Intelligence managed identity](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/how-to-guides/use-blob-sas)).
> For the demo, the simplest path is generating a SAS in a prior notebook step or temporarily allowing public Blob read on `raw/` (acceptable only in dev/demo, never production).

### F8.6 Activity [2c'] — Until + Web (poll DI result)

The DI `analyze` op returns immediately with `Operation-Location`; you must poll it until `status = succeeded` (or `failed`).

1. **Add activity → Until** after `di_analyze_submit`. Name it `poll_di_result`.
2. **Settings → Expression:** `@or(equals(activity('di_get_result').output.status, 'succeeded'), equals(activity('di_get_result').output.status, 'failed'))`
3. **Settings → Timeout:** `0.00:05:00` (5 minutes — increase for large files)
4. Inside the Until, add:
   - **Wait** activity `wait_2s` → 2 seconds
   - **Web** activity `di_get_result`:
     - **URL:** `@activity('di_analyze_submit').output.ADFWebActivityResponseHeaders['Operation-Location']`
     - **Method:** `GET`
     - **Headers:** `Ocp-Apim-Subscription-Key` → same Key Vault reference as F8.5

After the Until exits, the latest `di_get_result` output contains the full DI response under `.analyzeResult`. JSON-serialize it for the next step:

- Pipeline expression: `@string(activity('di_get_result').output)` → bind to the `di_result_json` parameter of the chunk notebook.

### F8.7 Activity [2d] — Chunk + upload

**Add activity → Notebook** after `poll_di_result`.

| Field | Value |
|---|---|
| **Name** | `chunk_and_upload` |
| **Notebook** | `nb_chunk_and_upload` |
| **Base parameters** | `file_id` = `@item().file_id`<br/>`di_result_json` = `@string(activity('di_get_result').output)`<br/>`raw_blob_uri` = `@variables('raw_blob_uri')`<br/>`chunks_account` = `<storage-account>`<br/>`chunks_container` = `chunks`<br/>`chunks_prefix` = `@concat(item().file_id, '/')` |

Capture the returned `chunk_count` for use in the next activity:

`@activity('chunk_and_upload').output.result.exitValue.chunk_count`

### F8.8 Activity [2e] — Update control table (succeeded)

**Add activity → Notebook** after `chunk_and_upload`.

| Field | Value |
|---|---|
| **Name** | `mark_succeeded` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`, `ingest_run_id` = `@pipeline().RunId`, `chunk_count` = `@activity('chunk_and_upload').output.result.exitValue.chunk_count`, `status` = `succeeded` |

### F8.9 On-failure handler

On the **red (failure) arrow** of any of [2a]/[2c]/[2d], add a final **Notebook** activity `mark_failed`:

| Field | Value |
|---|---|
| **Name** | `mark_failed` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`, `ingest_run_id` = `@pipeline().RunId`, `status` = `failed`, `last_error` = `@string(activity('<the-failing-activity>').error)` |

> For simplicity in the demo, attach `mark_failed` only to the `chunk_and_upload` failure arrow — that's the most common failure point. Production builds attach failure handlers to every step.

---

## Phase F9 — Validate end-to-end

### F9.1 Sample run

1. Pipeline editor → **Save** → **Run**
2. Watch the **Output** tab as each activity completes:
   - `lookup_new_files` → succeeded, returns `new_count > 0`
   - `foreach_new_file` → enters ForEach scope
   - For each iteration: all five inner activities succeed
3. Total runtime for 5 sample files: typically **3–8 minutes** (DI OCR is the dominant cost)

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

The AI Search indexer (Bicep- or manually-created, see [03-deployment-manual.md § Phase 4.3](./03-deployment-manual.md) or [04-deployment-automated.md § Step 4](./04-deployment-automated.md)) polls `chunks/` every 5 minutes. Within ~5 min of pipeline completion, the chunks should appear in the search index. Confirm:

```bash
GET https://<search-svc>.search.windows.net/indexers/ixr-chunks/status?api-version=2024-07-01
# Expected: lastResult.status = "success", itemsProcessed > 0
```

---

## Phase F10 — Schedule the pipeline

For demo, leave on manual trigger. For ongoing operation:

1. Pipeline editor → **Schedule**
2. **Status:** On
3. **Repeat:** Every 30 minutes (production batch) or every 5 minutes (low-latency demo, watch capacity cost)
4. **Apply**

Record the pipeline GUID in `demo-ids.local.json` under `fabric.pipelineId`.

---

## Validation checklist

- [ ] Tenant settings F0.1 confirmed by Fabric admin
- [ ] Capacity assigned to workspace (F-SKU, not trial in prod)
- [ ] Workspace identity created and Active
- [ ] Workspace identity granted **Storage Blob Data Contributor** on the storage account
- [ ] Lakehouse `lh_rag_<env>` created with `control_table_files` table
- [ ] OneLake shortcut at `Files/source_docs/` showing source documents
- [ ] Key Vault connection `kv-rag-<env>` created and tested
- [ ] Blob connection `blob-rag-<env>` created and tested
- [ ] Three notebooks (`nb_lookup_new_files`, `nb_chunk_and_upload`, `nb_update_control_table`) saved
- [ ] Pipeline `pl_ingest_docs` runs end-to-end on sample documents
- [ ] Control table populated; `raw/` and `chunks/` containers populated
- [ ] AI Search indexer picks up new chunks within 5 min
- [ ] Re-running the pipeline is a no-op (idempotency proved)

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

---

## Reference documentation

Authoritative Microsoft Learn pages this guide tracks:

- [Microsoft Fabric workspace identity](https://learn.microsoft.com/en-us/fabric/security/workspace-identity)
- [Trusted workspace access](https://learn.microsoft.com/en-us/fabric/security/security-trusted-workspace-access)
- [What is a lakehouse in Microsoft Fabric?](https://learn.microsoft.com/en-us/fabric/data-engineering/lakehouse-overview)
- [Create an internal OneLake shortcut](https://learn.microsoft.com/en-us/fabric/onelake/create-onelake-shortcut)
- [Create an ADLS Gen2 shortcut](https://learn.microsoft.com/en-us/fabric/onelake/create-adls-shortcut)
- [Set up your Azure Blob Storage connection](https://learn.microsoft.com/en-us/fabric/data-factory/connector-azure-blob-storage)
- [Web activity for REST API calls](https://learn.microsoft.com/en-us/fabric/data-factory/web-activity)
- [Copy data activity](https://learn.microsoft.com/en-us/fabric/data-factory/copy-data-activity)
- [Notebook activity in pipelines](https://learn.microsoft.com/en-us/fabric/data-factory/pipeline-notebook-activity)
- [Document Intelligence — analyze REST API](https://learn.microsoft.com/en-us/rest/api/aiservices/document-models/analyze-document)
- [Document Intelligence prebuilt-read model](https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/prebuilt/read)

---

*Last updated: 2026-05-22*

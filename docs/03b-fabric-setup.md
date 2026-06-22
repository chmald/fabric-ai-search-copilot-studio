# 03b — Fabric setup (manual — both deployment paths)

The Fabric layer of this pattern is **always manual**. Neither the manual Azure path ([03-deployment-manual.md](./03-deployment-manual.md)) nor the Bicep-automated path ([04-deployment-automated.md](./04-deployment-automated.md)) can provision Fabric items today — Fabric workspaces, Lakehouses, OneLake shortcuts, and Data Pipelines have no Bicep/ARM resource provider as of this pattern's publication, and the [Fabric REST APIs](https://learn.microsoft.com/en-us/rest/api/fabric/articles/) for items are only partially covered for automation.

> **Run this doc after Azure platform layer is up.** You need the Azure resources from [03-deployment-manual.md § Phase 1](./03-deployment-manual.md#phase-1--foundation) (manual) **or** the deployment outputs from [04-deployment-automated.md § Step 3](./04-deployment-automated.md) (automated) before you can wire the Fabric pipeline to them. Specifically you need: the storage account name, the **Microsoft Foundry resource's Cognitive Services endpoint** (which serves the Document Intelligence `prebuilt-read` API — there is no separate FormRecognizer resource in this pattern), and a Key Vault that holds the DI-caller service principal's client secret (no DI / Foundry API keys are stored anywhere; all DI calls go through the SP via MSAL).

> **Time budget.** First-time Fabric build: **2–3 hours** end-to-end. Subsequent rebuilds in the same tenant: **45–60 minutes** once the workspace identity, connections, and notebook artifacts can be reused.

---

## What you'll build

```
Azure side (one-time setup)
├── Service principal: sp-rag-di-caller
│     └── Cognitive Services User on the Microsoft Foundry resource
│         (Foundry serves the Document Intelligence prebuilt-read API —
│          no separate FormRecognizer resource in this pattern)
└── Key Vault secret: di-sp-secret  ← the SP's client secret

Fabric workspace (ws-rag-<env>)
├── Workspace identity (auto-created service principal)
│     ├── Storage Blob Data Contributor on Storage (raw/, chunks/)
│     └── Key Vault Secrets User on Key Vault (reads di-sp-secret)
├── Connections
│   └── Azure Blob Storage connection (writes raw/ + chunks/ via workspace identity)
├── Lakehouse: lh_rag_<env>
│   ├── Files/
│   │   └── source_docs/          ← OneLake shortcut to the source system
│   └── Tables/
│       ├── control_table_files   ← Delta state table (this pattern's source of truth)
│       └── _tmp_new_files        ← per-run handoff table from Lookup → ForEach
├── Notebooks
│   ├── nb_create_control_table   ← run once
│   ├── nb_lookup_new_files       ← called from pipeline activity [1]
│   ├── nb_ocr_chunk_upload       ← called from pipeline activity [2c]:
│   │                              MSAL→SP for DI auth, notebookutils→workspace
│   │                              identity for Blob; chunks DI result and writes
│   │                              chunk JSON to Blob
│   └── nb_update_control_table   ← called from pipeline activities [2b], [2d], on-error
└── Data Pipeline: pl_ingest_docs (parameters: storage_account, di_endpoint,
    │                                            key_vault_name, di_sp_*, etc.)
    ├── [1]   Notebook activity     → nb_lookup_new_files (writes _tmp_new_files)
    ├── [1.5] Refresh SQL Endpoint  → force SQL endpoint to sync Delta metadata
    ├── [1′]  Lookup activity       → read _tmp_new_files rows for the ForEach
    └── [2]   ForEach over Lookup output:
        ├── [2a] Copy data             → OneLake source → Blob raw/  (workspace-identity auth)
        ├── [2b] Notebook              → nb_update_control_table (status=pending)
        ├── [2c] Notebook              → nb_ocr_chunk_upload (DI → chunks/ JSON)
        ├── [2d] Notebook              → nb_update_control_table (status=succeeded)
        └── On-error handler           → nb_update_control_table (status=failed, last_error)
```

**Design rationale at a glance.** Document Intelligence is called from a notebook (not a pipeline Web activity) and the pipeline contains no `Until` loop — both choices work around real Fabric constraints documented in [Appendix A.1](#a1-no-web-activity-until-or-child-pipeline). The auth model uses Fabric's workspace identity for Blob + Key Vault and a dedicated service principal (`sp-rag-di-caller`) for Document Intelligence, scoped to the Foundry resource that hosts the DI endpoint — explained in [Appendix A.2](#a2-msal--service-principal-for-document-intelligence). All Azure services have local-key auth disabled; there are no API keys to store or rotate.

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

The pipeline writes raw files to `raw/` and chunk JSON to `chunks/`, and it reads a small secret from Key Vault that the DI-caller service principal (see [F2.2](#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook)) uses to authenticate to Document Intelligence. With all API keys disabled, the workspace identity needs two role assignments — grant them now before pipeline-build steps that depend on them.

From the **Azure portal** (or `az cli` — both shown):

```pwsh
# Identities + scopes
$WS_OBJID  = "<workspace-identity-object-id>"   # Microsoft Entra ID → Enterprise applications → search workspace name
$ST_RES_ID = az storage account show --name <storage-account> -g <rg> --query id -o tsv
$KV_RES_ID = az keyvault show --name <key-vault-name> --query id -o tsv

# 1. Write raw/ and chunks/ from Copy and chunk-upload activities
az role assignment create `
  --assignee-object-id $WS_OBJID --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" `
  --scope $ST_RES_ID

# 2. Read the DI-caller service-principal secret from Key Vault at notebook runtime
az role assignment create `
  --assignee-object-id $WS_OBJID --assignee-principal-type ServicePrincipal `
  --role "Key Vault Secrets User" `
  --scope $KV_RES_ID
```

> **Propagation:** Azure role assignments to Fabric workspace identities can take up to **15 minutes** to be honored end-to-end (Fabric token cache + Azure RBAC cache). If your first pipeline run fails with `401 Unauthorized` or `403 Forbidden`, wait and retry before debugging further.

### F2.2 Create a DI-caller service principal (for MSAL from the notebook)

Fabric notebooks **cannot** acquire a Microsoft Entra token for arbitrary Azure resources via the workspace identity — [`notebookutils.credentials.getToken`](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials#get-token) only supports four audience keys (`storage`, `pbi`, `keyvault`, `kusto`), and Cognitive Services is not one of them. `DefaultAzureCredential()` is also explicitly unsupported in Fabric notebooks.

For Document Intelligence (`https://cognitiveservices.azure.com/`), the supported path is **MSAL client-credentials with a dedicated service principal**, with the SP's client secret stored in Key Vault and fetched at notebook runtime via the workspace identity. This keeps API keys disabled on the Foundry resource (which serves the DI endpoint) while staying within Fabric's notebook auth surface.

1. **Create the service principal:**

   ```pwsh
   az ad sp create-for-rbac --name "sp-rag-di-caller" --years 1
   # Output:
   #   appId       = <client-id>      ← the SP's clientId (public)
   #   password    = <client-secret>  ← the SP's secret  (treat as secret)
   #   tenant      = <tenant-id>
   ```

   Note the `appId` and `tenant`. Copy the `password` to your clipboard — you'll store it in Key Vault next and it cannot be retrieved later.

2. **Grant the SP `Cognitive Services User` on the Foundry resource** (which serves the DI endpoint — see [01-architecture.md § 8](./01-architecture.md#8-document-intelligence-prebuilt-read-served-by-the-foundry-resource)):

   ```pwsh
   $SP_OBJID   = az ad sp show --id <client-id> --query id -o tsv
   $AIF_RES_ID = az cognitiveservices account show --name <foundry-resource> -g <rg> --query id -o tsv

   az role assignment create `
     --assignee-object-id $SP_OBJID --assignee-principal-type ServicePrincipal `
     --role "Cognitive Services User" `
     --scope $AIF_RES_ID
   ```

3. **Store the SP secret in Key Vault** under a name the notebook will reference (default: `di-sp-secret`):

   ```pwsh
   az keyvault secret set `
     --vault-name <key-vault-name> `
     --name di-sp-secret `
     --value '<the-password-from-step-1>'
   ```

4. **Record the three values** you'll bind into pipeline parameters in [F8.0](#f80-declare-pipeline-parameters):

   - `di_sp_tenant_id`   — the tenant guid from step 1
   - `di_sp_client_id`   — the appId from step 1
   - `di_sp_secret_name` — `di-sp-secret` (matches step 3)

> **Why this role goes on the SP, not the workspace identity** → [Appendix A.2](#a2-msal--service-principal-for-document-intelligence).

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

The pattern is source-agnostic: the OneLake shortcut layer normalizes whatever upstream document store you use (SharePoint Online, ADLS Gen2, S3, GCS, etc.) into a unified `Files/source_docs/` location that the pipeline reads from.

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

Use any document set with zero real data. The matching **structured** tables for the optional Fabric Data Agent ship in [`samples/structured/`](../samples/structured/) (see [03e](./03e-fabric-data-agent.md)); the document corpus is uploaded here separately to trigger the flow.

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

Fabric pipelines authenticate to external services through **connections**. For this pattern you only need to pre-create **one connection** — Azure Blob Storage — for the Copy activity. Document Intelligence is called from a Fabric notebook (`nb_ocr_chunk_upload`) using the `azure-ai-documentintelligence` Python SDK with **MSAL + a dedicated service principal** (see [F2.2](#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook) and [F7.2](#f72-nb_ocr_chunk_upload)) — so no DI connection and no Web activity are required. The SP's secret lives in Key Vault and is fetched at notebook runtime via the workspace identity's Key Vault Secrets User role.

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
from pyspark.sql.functions import col, md5, concat_ws, regexp_replace, lit

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

# ---------------------------------------------------------------------------
# Pick up two categories of files:
#   1. BRAND NEW   — not in control_table_files at all (left_anti)
#   2. RETRY       — already in control_table_files but any per-stage status
#                    is 'failed' AND the row is not tombstoned (manual skip).
# mark_pending uses MERGE … WHEN MATCHED THEN UPDATE, so the retry rows are
# flipped back to 'pending' on the next run and either 'succeeded' or 'failed'
# at the end — no schema changes needed. Set tombstoned=true in the control
# table to permanently stop retrying a specific file_id.
# ---------------------------------------------------------------------------
ctrl = spark.table("control_table_files")

brand_new = src.join(ctrl.select("file_id"), on="file_id", how="left_anti")

retry_ids = (
    ctrl
    .filter(
        (col("tombstoned").isNull() | (col("tombstoned") == lit(False))) &
        ((col("ocr_status")   == "failed") |
         (col("chunk_status") == "failed") |
         (col("index_status") == "failed"))
    )
    .select("file_id")
)
retry_files = src.join(retry_ids, on="file_id", how="inner")

to_process = brand_new.unionByName(retry_files).dropDuplicates(["file_id"])

# Persist for the pipeline's Lookup activity to read
(to_process
    .select("file_id", "source_path",
            col("source_modified_ts").cast("string").alias("source_modified_ts"),
            "byte_size")
    .write.format("delta").mode("overwrite").saveAsTable("_tmp_new_files"))

# Return JSON-serialized summary as the notebook exit value.
# notebookutils.notebook.exit(value) takes a STRING; the pipeline receives it at
# @activity('lookup_new_files').output.result.exitValue
new_count   = brand_new.count()
retry_count = retry_files.count()
exit_payload = json.dumps({
    "new_count":   new_count,
    "retry_count": retry_count,
    "total":       new_count + retry_count,
})
notebookutils.notebook.exit(exit_payload)
```

> **`notebookutils.notebook.exit(value)`** returns a single string from a notebook activity (use `json.dumps(...)` for structured data). The legacy `mssparkutils` namespace still works but is being retired. See [NotebookUtils notebook run and orchestration](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-notebook-run#exit-a-notebook).
>
> **Retry behavior.** The lookup picks up brand-new files **and** any row in `control_table_files` where any per-stage status is `'failed'` (unless `tombstoned = true`). `mark_pending` uses `MERGE … WHEN MATCHED THEN UPDATE`, so retries flip the existing row through `pending` → `succeeded`/`failed` automatically. The exit payload reports `{"new_count": N, "retry_count": M, "total": N+M}`. Full operating playbook (manual retry, tombstoning a corrupt file, bulk reprocess): [06-troubleshooting.md § 3.11](./06-troubleshooting.md#311-failed-files-are-not-retried-on-the-next-pipeline-run). Background on the staging-table design: [Appendix A.3](#a3-staging-delta-table-for-the-foreach-handoff).

### F7.2 `nb_ocr_chunk_upload`

This notebook calls Document Intelligence, chunks the resulting text, and uploads chunk JSON to Blob — all in one Spark session per file. It uses the official [`azure-ai-documentintelligence`](https://learn.microsoft.com/python/api/overview/azure/ai-documentintelligence-readme) Python SDK. The SDK's long-running-operation poller waits for DI's async `analyze` operation to finish, so the pipeline doesn't need an `Until` loop.

**Auth model.** Fabric notebooks do **not** support `DefaultAzureCredential` and `notebookutils.credentials.getToken` only accepts four documented audience keys (`storage`, `pbi`, `keyvault`, `kusto`) — see the [auth callout in F2.2](#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook). The notebook therefore uses:

- **Blob** → a custom `TokenCredential` wrapping `notebookutils.credentials.getToken('storage')` (workspace identity)
- **Document Intelligence** → [MSAL](https://learn.microsoft.com/entra/msal/python/) client-credentials flow with the DI-caller service principal from F2.2, whose secret is read at runtime from Key Vault via `notebookutils.credentials.getSecret`

Parameters expected:

- `file_id` (string)
- `raw_blob_uri` (string)
- `chunks_account` (string)
- `chunks_container` (string) — `chunks`
- `chunks_prefix` (string) — typically `f"{file_id}/"`
- `di_endpoint` (string) — the **Foundry resource's** Cognitive Services endpoint, which serves the DI API. Format: `https://<foundry-name>.cognitiveservices.azure.com` (note: different host suffix from the OpenAI `<foundry-name>.openai.azure.com` host used by the AI Search vectorizer — same resource, two host names).
- `key_vault_name` (string) — e.g. `kv-rag-demo-eus`
- `di_sp_tenant_id` (string) — from F2.2 step 1
- `di_sp_client_id` (string) — from F2.2 step 1
- `di_sp_secret_name` (string) — default `di-sp-secret`

```python
# Parameters (overridden by pipeline)
file_id           = ""
raw_blob_uri      = ""
chunks_account    = ""
chunks_container  = "chunks"
chunks_prefix     = ""
di_endpoint       = ""
key_vault_name    = ""
di_sp_tenant_id   = ""
di_sp_client_id   = ""
di_sp_secret_name = "di-sp-secret"

# Install required packages (cached in the session after first install)
# pyjwt>=2.6.0 is pinned explicitly to satisfy Fabric's preinstalled fsspec-wrapper;
# msal's loose pyjwt constraint otherwise resolves to an older version and produces
# a pip dependency-conflict warning (see 06-troubleshooting.md § 3.10).
%pip install azure-ai-documentintelligence==1.0.0 azure-storage-blob==12.21.0 azure-core==1.30.2 msal==1.30.0 "pyjwt>=2.6.0" tiktoken==0.7.0 --quiet
```

> **`%pip install` is disabled in pipeline runs by default.** Per [Manage Apache Spark libraries in Microsoft Fabric](https://learn.microsoft.com/fabric/data-engineering/library-management#inline-installation), Fabric blocks inline `%pip` in pipeline-triggered notebook runs (it works fine in interactive runs from the notebook editor). You have two ways to make the cell above work from the pipeline:
>
> - **Quick fix** — pass `_inlineInstallationEnabled = true` as a **base parameter** on the `ocr_chunk_upload` notebook activity in the pipeline (see [F8.7](#f87-activity-2c--ocr--chunk--upload-notebook)). This re-enables `%pip` for that specific activity. Best for demo / proof-of-concept.
> - **Production pattern (recommended)** — create a Fabric **Environment** (e.g. `env-rag-<env>`) with these packages installed in **Full mode**, then attach the environment to `nb_ocr_chunk_upload`. Once the environment is attached, **delete the `%pip install` cell** (libraries are loaded by Fabric when the Spark session starts). See [Manage libraries in Fabric environments](https://learn.microsoft.com/fabric/data-engineering/environment-manage-library). Full mode adds 1–3 minutes to session startup but eliminates per-run resolution variance.

```python
import json
import time
import tiktoken
import msal
from azure.ai.documentintelligence import DocumentIntelligenceClient
from azure.ai.documentintelligence.models import AnalyzeDocumentRequest
from azure.core.credentials import AccessToken, TokenCredential
from azure.storage.blob import BlobServiceClient

# ---------- 1. Custom TokenCredential bridging notebookutils → Azure SDK ------
# Fabric notebooks don't support DefaultAzureCredential, so we provide a small
# adapter that produces TokenCredential-shaped objects from a token-fetching
# function. Azure SDK clients accept any object that implements get_token(scope).

class _StaticTokenCredential(TokenCredential):
    """Wraps a callable[() -> str] that returns a fresh Entra access token."""

    def __init__(self, fetch_token):
        self._fetch = fetch_token

    def get_token(self, *scopes, **_kwargs):
        token = self._fetch()
        # AccessToken is a NamedTuple(token=str, expires_on=int). We don't know
        # the real expiry; subtract a 5-minute safety margin from "now + 1h"
        # which is the typical AAD token lifetime. SDKs that respect expiry will
        # request a fresh token via _fetch when needed.
        return AccessToken(token, int(time.time()) + 55 * 60)


# ---------- 2. Blob credential = workspace identity via notebookutils --------
blob_cred = _StaticTokenCredential(
    lambda: notebookutils.credentials.getToken("storage")
)


# ---------- 3. DI credential = MSAL client-credentials with DI-caller SP -----
# Read the SP client secret from Key Vault at runtime (the workspace identity
# has Key Vault Secrets User from F2.1). Then use MSAL to acquire a token for
# Cognitive Services on behalf of the SP.

_kv_uri = f"https://{key_vault_name}.vault.azure.net/"
_di_sp_secret = notebookutils.credentials.getSecret(_kv_uri, di_sp_secret_name)

_msal_app = msal.ConfidentialClientApplication(
    client_id=di_sp_client_id,
    client_credential=_di_sp_secret,
    authority=f"https://login.microsoftonline.com/{di_sp_tenant_id}",
)

def _di_token():
    result = _msal_app.acquire_token_for_client(
        scopes=["https://cognitiveservices.azure.com/.default"]
    )
    if "access_token" not in result:
        raise RuntimeError(
            f"MSAL failed to acquire DI token: "
            f"{result.get('error')}: {result.get('error_description')}"
        )
    return result["access_token"]

di_cred = _StaticTokenCredential(_di_token)


# ---------- 4. Call Document Intelligence with the SP-derived bearer token ---
# The SDK's begin_analyze_document().result() polls the async analyze operation
# internally so the pipeline doesn't need an Until loop.

di_client = DocumentIntelligenceClient(endpoint=di_endpoint, credential=di_cred)
poller    = di_client.begin_analyze_document(
    model_id="prebuilt-read",
    body=AnalyzeDocumentRequest(url_source=raw_blob_uri),
)
di_result = poller.result().as_dict()


# ---------- 5. Page-aware chunker with token budget + overlap ---------------
CHUNK_TOKENS   = 1000
OVERLAP_TOKENS = 200
ENCODING       = tiktoken.encoding_for_model("gpt-4o")

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

raw_pages = di_result.get("pages", [])
flat_pages = [
    {
        "pageNumber": p.get("pageNumber") or p.get("page_number"),
        "content":    " ".join(line["content"] for line in p.get("lines", [])),
    }
    for p in raw_pages
]
chunks = chunk_pages(flat_pages)


# ---------- 6. Upload one JSON per chunk to Blob via workspace identity ------
svc = BlobServiceClient(
    account_url=f"https://{chunks_account}.blob.core.windows.net",
    credential=blob_cred,
)
container = svc.get_container_client(chunks_container)

# Security trimming (chunk-level access control). Source ACLs do NOT survive
# OCR/chunking, so the source document's permissions must be propagated into
# every derived chunk here (push model). Resolve the source doc's permissions to
# a list of Entra **group object IDs** allowed to see it; [] means "all
# authenticated users". Implement resolve_source_group_ids() against your source
# system (SharePoint/Graph, ADLS ACLs, a permissions table, etc.).
doc_group_ids = resolve_source_group_ids(file_id)  # -> list[str]; [] = visible to all

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
        "group_ids":  doc_group_ids,   # Entra group IDs permitted to see this chunk (security trimming)
        "metadata":   "{}",
    }
    blob_name = f"{chunks_prefix}{file_id}-{i:04d}.json"
    container.upload_blob(name=blob_name, data=json.dumps(payload), overwrite=True)

notebookutils.notebook.exit(json.dumps({"chunk_count": len(chunks)}))
```

> **`urlSource` access requires the Foundry resource's managed identity** (Document Intelligence runs inside the Foundry account in this pattern) to have **Storage Blob Data Reader** on the storage account (shared-key access is disabled). The Bicep `rbac.bicep` module grants this automatically; manual deployments wire it in [03-deployment-manual.md § 1.7 step 3](./03-deployment-manual.md#17-rbac-wiring). If you see `InvalidContent: Could not download the file` at runtime, see [06-troubleshooting.md § 3.9](./06-troubleshooting.md#39-document-intelligence-invalidcontent-could-not-download-the-file).
>
> Rationale for the MSAL + SP auth model (rather than using the workspace identity directly): [Appendix A.2](#a2-msal--service-principal-for-document-intelligence).

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
from datetime import datetime, timezone

# ---------- coercion helpers --------------------------------------------------
# Fabric pipeline base parameters arrive at the notebook as STRINGS by default,
# so byte_size / page_count / chunk_count / timestamps need to be coerced before
# we hand them to Spark. Empty strings come through when the pipeline expression
# resolves to null.

def _coerce_int(v):
    if v is None or v == "" or v == "None":
        return None
    return int(v)

def _coerce_ts(v):
    if v is None or v == "" or v == "None":
        return None
    if isinstance(v, datetime):
        return v
    s = str(v).replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None

# ---------- build the row using the TABLE's existing schema -------------------
# spark.createDataFrame can't infer types from a row that's mostly None, which is
# exactly the shape of a mark_pending row. Pull the schema from the existing
# Delta table and pass it explicitly to side-step type inference entirely. This
# fixes PySparkValueError: CANNOT_DETERMINE_TYPE.

schema = spark.table("control_table_files").schema

now          = datetime.now(timezone.utc)
completed_ts = now if status == "succeeded" else None

row_tuple = (
    file_id,
    source_path,
    _coerce_ts(source_modified_ts),
    raw_blob_uri,
    chunks_prefix,
    "generic",                  # doc_type
    _coerce_int(byte_size),
    _coerce_int(page_count),
    ingest_run_id,
    now,                        # ingest_ts
    status,                     # ocr_status
    completed_ts,               # ocr_completed_ts
    status,                     # chunk_status
    _coerce_int(chunk_count),
    completed_ts,               # chunk_completed_ts
    status,                     # index_status
    last_error,
    False,                      # tombstoned
)
row = spark.createDataFrame([row_tuple], schema)
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
2. Open the pipeline.

### F8.0 Declare pipeline parameters

Select the **Parameters** tab (bottom pane) and add the following — all string type. These eliminate hard-coded values from individual activity expressions and make the pipeline portable across environments by editing a single place.

| Name | Default value (example) | Used by |
|---|---|---|
| `storage_account` | `stragdemoeus` | Copy sink (F8.5), `mark_pending` (F8.6), `ocr_chunk_upload` (F8.7) |
| `raw_container` | `raw` | Copy sink (F8.5), `mark_pending` (F8.6), `ocr_chunk_upload` (F8.7) |
| `chunks_container` | `chunks` | `ocr_chunk_upload` (F8.7) |
| `di_endpoint` | `https://aif-rag-demo-eus.cognitiveservices.azure.com` (the **Foundry** resource's Cognitive Services host — serves DI) | `ocr_chunk_upload` (F8.7) |
| `key_vault_name` | `kv-rag-demo-eus` | `ocr_chunk_upload` (F8.7) |
| `di_sp_tenant_id` | `<tenant-guid-from-F2.2>` | `ocr_chunk_upload` (F8.7) |
| `di_sp_client_id` | `<client-id-from-F2.2>` | `ocr_chunk_upload` (F8.7) |
| `di_sp_secret_name` | `di-sp-secret` | `ocr_chunk_upload` (F8.7) |
| `source_folder` | `Files/source_docs/` | `lookup_new_files` (F8.1) |

### F8.1 Activity [1] — Lookup new files (Notebook)

| Field | Value |
|---|---|
| **General → Name** | `lookup_new_files` |
| **Settings → Notebook** | `nb_lookup_new_files` |
| **Settings → Base parameters** | `source_path` = `@pipeline().parameters.source_folder` |

Reference: [Transform data by running a notebook (Fabric)](https://learn.microsoft.com/fabric/data-factory/notebook-activity).

### F8.2 Activity [1.5] — Refresh SQL Endpoint

> **Required** because the Lookup activity in [F8.3](#f83-activity-1--lookup-read-_tmp_new_files-for-the-foreach) reads `_tmp_new_files` via the Lakehouse SQL analytics endpoint, but `nb_lookup_new_files` wrote that table through Spark. The SQL endpoint syncs Delta metadata via a **background process** — syncs can lag seconds to minutes behind Spark writes ([SQL analytics endpoint metadata sync](https://learn.microsoft.com/fabric/data-engineering/sql-analytics-endpoint-metadata-sync)). Without this refresh, the first run will Lookup zero rows and the ForEach will iterate zero times, even though `nb_lookup_new_files` just wrote N rows. Microsoft's first documented [common scenario for this activity](https://learn.microsoft.com/fabric/data-factory/refresh-sql-endpoint-activity#common-scenarios) is exactly this case: *"Refreshing the SQL endpoint after a Notebook writes transformed data to a Lakehouse."*

Drag a **Refresh SQL Endpoint** activity after `lookup_new_files`. Connect with the green (success) arrow.

| Field | Value |
|---|---|
| **General → Name** | `refresh_sql_endpoint` |
| **Settings → Connection** | create or reuse a Fabric workspace connection |
| **Settings → Workspace** | `ws-rag-<env>` |
| **Settings → SQL Endpoint** | the SQL analytics endpoint for `lh_rag_<env>` (named the same as the lakehouse) |

A `NotRun` outcome here is **OK** — it means there's nothing new to sync since the last refresh, which can happen on idempotent re-runs.

### F8.3 Activity [1′] — Lookup (read `_tmp_new_files` for the ForEach)

The notebook persisted the new-file list to `_tmp_new_files`. A pipeline **Lookup** activity reads it back as a typed row array the ForEach can iterate.

Drag a **Lookup** activity after `refresh_sql_endpoint`. Connect with the green (success) arrow.

| Field | Value |
|---|---|
| **General → Name** | `lookup_new_files_rows` |
| **Settings → Connection** | `lh_rag_<env>` (Lakehouse) — use the SQL analytics endpoint flavor |
| **Settings → Use query** | **Query** |
| **Settings → Query** | `SELECT file_id, source_path, source_modified_ts, byte_size FROM _tmp_new_files` |
| **Settings → First row only** | **Off** (we want all rows) |

The output is then bound as `@activity('lookup_new_files_rows').output.value` (an array).

### F8.4 Activity [2] — ForEach over new files

Drag a **ForEach** activity onto the canvas after `lookup_new_files_rows`. Connect them with the green (success) arrow.

| Field | Value |
|---|---|
| **General → Name** | `foreach_new_file` |
| **Settings → Items** | `@activity('lookup_new_files_rows').output.value` |
| **Settings → Sequential** | **Off** for parallelism; cap with **Batch count** = 4 for the demo (raise per capacity headroom) |

Inside the ForEach, add the following four activities in sequence:

### F8.5 Activity [2a] — Copy data (OneLake source → Blob raw/)

Inside the ForEach, **Add activity → Copy data**.

| Field | Value |
|---|---|
| **General → Name** | `copy_raw_to_blob` |
| **Source → Connection** | `lh_rag_<env>` (Lakehouse) |
| **Source → Root folder** | `Files` |
| **Source → File path** | `@item().source_path` (this is a path **relative to the Files root**, e.g. `source_docs/<filename>` — the lookup notebook strips the absolute `abfss://...` prefix before writing to `_tmp_new_files`) |
| **Source → File format** | **Binary** (preserves bytes) |
| **Sink → Connection** | `blob-rag-<env>` (from F6.1) |
| **Sink → Container** | `@pipeline().parameters.raw_container` |
| **Sink → File path** | `@concat(item().file_id, '/', last(split(item().source_path, '/')))` |
| **Sink → File format** | **Binary** |

Reference: [Configure Lakehouse in a copy activity](https://learn.microsoft.com/fabric/data-factory/connector-lakehouse-copy-activity).

> **If you see `PathNotFound`** with a path that contains `Files/abfss:/...`, the lookup notebook is writing absolute URIs to `_tmp_new_files` instead of relative paths. The `regexp_replace(...)` line in [F7.1](#f71-nb_lookup_new_files) is the fix — see also [06-troubleshooting.md § 3.5](./06-troubleshooting.md#35-copy-activity-fails-with-pathnotfound-and-an-abfss-uri-in-the-path).

### F8.6 Activity [2b] — Update control table (pending)

**Add activity → Notebook** after the Copy.

| Field | Value |
|---|---|
| **Name** | `mark_pending` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`<br/>`source_path` = `@item().source_path`<br/>`source_modified_ts` = `@item().source_modified_ts`<br/>`raw_blob_uri` = `@concat('https://', pipeline().parameters.storage_account, '.blob.core.windows.net/', pipeline().parameters.raw_container, '/', item().file_id, '/', last(split(item().source_path, '/')))`<br/>`chunks_prefix` = `@concat(item().file_id, '/')`<br/>`byte_size` = `@item().byte_size`<br/>`ingest_run_id` = `@pipeline().RunId`<br/>`status` = `pending` |

### F8.7 Activity [2c] — OCR + chunk + upload (Notebook)

This activity is where Document Intelligence is called. The notebook ([F7.2](#f72-nb_ocr_chunk_upload)) uses MSAL with the DI-caller service principal (secret read from Key Vault at runtime) to authenticate to DI, and a notebookutils-backed `TokenCredential` for Blob. The DI SDK's long-running-operation poller handles the async wait internally — no `Until` activity needed.

**Add activity → Notebook** after `mark_pending`.

| Field | Value |
|---|---|
| **Name** | `ocr_chunk_upload` |
| **Notebook** | `nb_ocr_chunk_upload` |
| **Base parameters** | `file_id` = `@item().file_id`<br/>`raw_blob_uri` = `@concat('https://', pipeline().parameters.storage_account, '.blob.core.windows.net/', pipeline().parameters.raw_container, '/', item().file_id, '/', last(split(item().source_path, '/')))`<br/>`chunks_account` = `@pipeline().parameters.storage_account`<br/>`chunks_container` = `@pipeline().parameters.chunks_container`<br/>`chunks_prefix` = `@concat(item().file_id, '/')`<br/>`di_endpoint` = `@pipeline().parameters.di_endpoint`<br/>`key_vault_name` = `@pipeline().parameters.key_vault_name`<br/>`di_sp_tenant_id` = `@pipeline().parameters.di_sp_tenant_id`<br/>`di_sp_client_id` = `@pipeline().parameters.di_sp_client_id`<br/>`di_sp_secret_name` = `@pipeline().parameters.di_sp_secret_name`<br/>**`_inlineInstallationEnabled` = `true`** — required because the notebook installs PyPI packages via `%pip install` (see [F7.2](#f72-nb_ocr_chunk_upload) callout). If you attach a [Fabric Environment](https://learn.microsoft.com/fabric/data-engineering/environment-manage-library) instead, omit this parameter and delete the `%pip install` cell from the notebook. |

The notebook returns `{"chunk_count": N}` as its exit value. The next activity parses it with `@json(activity('ocr_chunk_upload').output.result.exitValue).chunk_count`.

### F8.8 Activity [2d] — Update control table (succeeded)

**Add activity → Notebook** after `ocr_chunk_upload`.

| Field | Value |
|---|---|
| **Name** | `mark_succeeded` |
| **Notebook** | `nb_update_control_table` |
| **Base parameters** | `file_id` = `@item().file_id`, `ingest_run_id` = `@pipeline().RunId`, `chunk_count` = `@json(activity('ocr_chunk_upload').output.result.exitValue).chunk_count`, `status` = `succeeded` |

### F8.9 On-failure handler

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
   - `refresh_sql_endpoint` → `Success` or `NotRun` (both are OK)
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

Open one chunk JSON and verify it has `id`, `doc_id`, `chunk_id`, `content`, `source_uri`, `page_start`, `page_end`, `ingest_ts`, `group_ids`, `metadata`. For security-trimmed corpora, confirm `group_ids` holds the expected Entra group object IDs (or `[]` for open documents).

### F9.3 Idempotency

Re-run the pipeline with no source changes. Expected:

- `lookup_new_files` returns `new_count = 0`
- ForEach iterates zero times
- Pipeline succeeds in seconds
- Zero new rows in `control_table_files`, zero new blob writes

If the second run re-processes files, your `file_id` hash isn't stable. See [06-troubleshooting.md § 3.4](./06-troubleshooting.md#34-pipeline-runs-duplicate-files).

### F9.4 Hand off to AI Search

The AI Search indexer (Bicep- or manually-created, see [03-deployment-manual.md § Phase 4](./03-deployment-manual.md#phase-4--ai-search-index) or [04-deployment-automated.md § Step 4](./04-deployment-automated.md)) polls `chunks/` every 5 minutes. Within ~5 min of pipeline completion, the chunks should appear in the search index. Confirm:

```http
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
- [ ] Workspace identity granted **Key Vault Secrets User** on the Key Vault (for reading the DI-caller SP secret)
- [ ] DI-caller service principal (`sp-rag-di-caller`) created
- [ ] DI-caller SP granted **Cognitive Services User** on the Foundry resource (which serves the DI endpoint — no separate FormRecognizer resource)
- [ ] DI-caller SP secret stored in Key Vault as `di-sp-secret`
- [ ] Lakehouse `lh_rag_<env>` created with `control_table_files` table
- [ ] OneLake shortcut at `Files/source_docs/` showing source documents
- [ ] Blob connection `blob-rag-<env>` created and tested
- [ ] Three notebooks (`nb_lookup_new_files`, `nb_ocr_chunk_upload`, `nb_update_control_table`) saved and runnable manually with sample parameter values
- [ ] Pipeline `pl_ingest_docs` has the 9 pipeline parameters from [F8.0](#f80-declare-pipeline-parameters) declared with environment-correct defaults
- [ ] Pipeline `pl_ingest_docs` runs end-to-end on sample documents
- [ ] Control table populated; `raw/` and `chunks/` containers populated
- [ ] AI Search indexer picks up new chunks within 5 min
- [ ] Re-running the pipeline is a no-op (idempotency proved — ForEach iterates zero times)

When all boxes are checked → continue to [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md) to build the Copilot Studio agent on top of the populated AI Search index.

---

## Troubleshooting pointers

Common Fabric-layer issues are catalogued in [06-troubleshooting.md](./06-troubleshooting.md):

- **OneLake shortcut shows no files / can't be read** → [§ 2](./06-troubleshooting.md#2--onelake--source-attachment)
- **`copy_raw_to_blob` fails with `PathNotFound` and an `abfss:/...` URI in the path** → [§ 3.5](./06-troubleshooting.md#35-copy-activity-fails-with-pathnotfound-and-an-abfss-uri-in-the-path) — `nb_lookup_new_files` is writing absolute abfss URIs instead of paths relative to `Files/`
- **Lookup activity returns zero rows on first run** even though `nb_lookup_new_files` wrote N rows → [§ 3.6](./06-troubleshooting.md#36-lookup-activity-returns-zero-rows-after-a-spark-write) — SQL analytics endpoint sync lag; add a Refresh SQL Endpoint activity ([F8.2](#f82-activity-15--refresh-sql-endpoint))
- **`nb_ocr_chunk_upload` fails with `ImportError: cannot import name 'DefaultAzureCredential'` or auth errors against DI** → [§ 3.7](./06-troubleshooting.md#37-nb_ocr_chunk_upload-cant-authenticate-to-document-intelligence) — Fabric notebooks don't support `DefaultAzureCredential`; use the MSAL+SP pattern in [F7.2](#f72-nb_ocr_chunk_upload)
- **`nb_ocr_chunk_upload` fails with `MagicUsageError: %pip magic command is disabled`** → [§ 3.8](./06-troubleshooting.md#38-pip-install-fails-with-magicusageerror-pip-magic-command-is-disabled) — pipeline runs block `%pip`; either add `_inlineInstallationEnabled = true` to the activity ([F8.7](#f87-activity-2c--ocr--chunk--upload-notebook)) or attach a Fabric Environment
- **`nb_ocr_chunk_upload` fails with `InvalidContent: Could not download the file from the given URL`** → [§ 3.9](./06-troubleshooting.md#39-document-intelligence-invalidcontent-could-not-download-the-file) — the **Foundry resource's MI** is missing **Storage Blob Data Reader** on the storage account (DI runs inside the Foundry account; it tries to fetch `urlSource` and storage rejects it because shared-key is disabled)
- **`nb_ocr_chunk_upload` pip warning `fsspec-wrapper requires PyJWT>=2.6.0, but you have pyjwt 2.4.0`** → [§ 3.10](./06-troubleshooting.md#310-pyjwt-dependency-conflict-warning) — msal pulls an older PyJWT than Fabric's preinstalled fsspec-wrapper accepts; pin `pyjwt>=2.6.0` in the install line
- **Failed files in `control_table_files` are not retried — lookup reports `new_count: 0`** → [§ 3.11](./06-troubleshooting.md#311-failed-files-are-not-retried-on-the-next-pipeline-run) — `nb_lookup_new_files` needs the brand-new + failed union (see [F7.1](#f71-nb_lookup_new_files)); the pattern also covers manual retry and tombstoning
- **`nb_ocr_chunk_upload` import errors on `%pip install`** → [§ 3.2](./06-troubleshooting.md#32-chunking-notebook-fails) — the install cell didn't run or session is stale
- **Control table never updates** → [§ 3.3](./06-troubleshooting.md#33-control-table-stuck)
- **`mark_pending` / `mark_succeeded` fails with `PySparkValueError: CANNOT_DETERMINE_TYPE`** → [§ 3.3.1](./06-troubleshooting.md#331-nb_update_control_table-fails-with-pysparkvalueerror-cannot_determine_type) — `nb_update_control_table` is letting PySpark infer the schema from a mostly-None row; pull the schema from the table instead
- **Same files re-processed every run** → [§ 3.4](./06-troubleshooting.md#34-pipeline-runs-duplicate-files)
- **Fabric capacity cost spike** → [§ 6.1](./06-troubleshooting.md#61-fabric-capacity-cost-spike) (consider enabling High concurrency mode for the pipeline; see [F10](#phase-f10--schedule-the-pipeline))
- **Workspace identity Blob writes 403** → [§ 1.1 RBAC propagation lag](./06-troubleshooting.md#11-rbac-propagation-lag)
- **"Activity of type 'Until' is not supported inside a 'ForEach' activity"** → this pattern deliberately uses no `Until` activity at all. If you've added one and hit this error, fold the polled operation into a Fabric notebook instead (as `nb_ocr_chunk_upload` does for Document Intelligence). Reference: [ForEach activity limitations](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds).

---

## Appendix A — Design notes

Background on the non-obvious shape choices in this pipeline. None of these are required reading to build it — they explain **why** the build steps look the way they do, for reviewers and future maintainers.

### A.1 No Web activity, Until, or child pipeline

The natural ADF-style pattern for calling Document Intelligence from a pipeline would be: **Web activity** to submit the analyze job → **Until** loop to poll for completion → **Web activity** to fetch the result. None of that works in Fabric Data Factory today:

| Constraint | Detail | Reference |
|---|---|---|
| Fabric Web activity has **no inline MI + Resource fields** | The Fabric Web activity only takes a connection from **Manage connections and gateways**. The Web v2 connector's `Workspace identity` auth is supported in Dataflow Gen2 only, not in pipelines, so there is no way to call an MI-protected endpoint that doesn't have a pre-configured connection. | [Web v2 connector overview](https://learn.microsoft.com/fabric/data-factory/connector-web-overview), [ADF/Fabric connector parity](https://learn.microsoft.com/fabric/data-factory/connector-parity) |
| `Until` cannot nest inside `ForEach` | A documented Fabric/ADF limitation. Polling per-file from inside the per-file ForEach is therefore impossible at the pipeline-control-flow level. | [ForEach limitations](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds), [Nested activity embedding limitations](https://learn.microsoft.com/azure/data-factory/concepts-nested-activities#nested-activity-embedding-limitations) |
| Invoke-pipeline workaround adds complexity | A child pipeline can host the Until loop, but it doubles the activity count, complicates parameter passing, and obscures the per-file failure attribution. |  |

**The fix used here.** Call Document Intelligence from a Fabric **notebook** ([F7.2](#f72-nb_ocr_chunk_upload)) using the [`azure-ai-documentintelligence`](https://learn.microsoft.com/python/api/overview/azure/ai-documentintelligence-readme) SDK. The SDK's `begin_analyze_document().result()` polls the async operation internally, so the pipeline doesn't need an `Until` loop at all. The OCR call, chunking, and chunk upload happen in a single Spark session per file.

### A.2 MSAL + service principal for Document Intelligence

Fabric notebooks have two hard auth constraints that shape the DI auth pattern:

1. **`DefaultAzureCredential` is not supported.** See [NotebookUtils credentials](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials#get-token).
2. **`notebookutils.credentials.getToken(audience)` accepts only four documented audiences**: `storage`, `pbi`, `keyvault`, `kusto`. Cognitive Services is not on the list, so the workspace identity cannot directly mint a DI bearer token from a notebook.

The workspace identity also cannot be used with MSAL — its client secret isn't exposed to notebook code.

**The fix.** Register a dedicated service principal `sp-rag-di-caller` ([F2.2](#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook)) and grant it **Cognitive Services User** on the Foundry resource (which serves the DI endpoint — see [01-architecture.md § 8](./01-architecture.md#8-document-intelligence-prebuilt-read-served-by-the-foundry-resource)). Store the SP's client secret in Key Vault; the notebook reads it at runtime via `notebookutils.credentials.getSecret` (the workspace identity has **Key Vault Secrets User** on the vault from [F2.1](#f21-grant-the-workspace-identity-the-required-roles)), then uses [MSAL's `ConfidentialClientApplication`](https://learn.microsoft.com/entra/msal/python/) to acquire a token for `https://cognitiveservices.azure.com/.default`.

> The role assignment must be on the **SP**, not the workspace identity — the workspace identity is never the principal that calls DI.

### A.3 Staging Delta table for the ForEach handoff

The natural shape would be: notebook returns the new-file list inline → ForEach iterates the returned array. That doesn't work cleanly in Fabric:

- The notebook activity's `exitValue` is a **single string**. Complex shapes have to round-trip through `json.dumps`.
- Spark `Row` objects with timestamps and nested types don't serialize cleanly with `json.dumps` and lose typing on the consumer side.

**The fix.** `nb_lookup_new_files` writes the file list to a Delta table `_tmp_new_files`, then a pipeline **Lookup** activity ([F8.3](#f83-activity-1--lookup-read-_tmp_new_files-for-the-foreach)) reads the table and feeds the typed row array to the ForEach. Side benefits:

- The table is queryable from the SQL analytics endpoint — easy to inspect what the last run picked up.
- The Lookup activity natively returns the row array as `@activity('...').output.value`, which the ForEach's `Items` expression consumes directly.
- The notebook can still return a small JSON summary via `notebookutils.notebook.exit(...)` for logging / monitoring.

The one operational caveat is SQL-endpoint sync lag (Delta writes via Spark take seconds-to-minutes to surface in the SQL endpoint), which is why the pipeline has a **Refresh SQL Endpoint** activity between the notebook and the Lookup ([F8.2](#f82-activity-15--refresh-sql-endpoint)). See [06-troubleshooting.md § 3.6](./06-troubleshooting.md#36-lookup-activity-returns-zero-rows-after-a-spark-write).

### A.4 Retry model for failed files

`nb_lookup_new_files` returns **two categories** of files: brand-new (not in `control_table_files`) and retry-eligible (in the table but with any per-stage status = `'failed'` and `tombstoned != true`). This is a deliberate choice over the simpler "left-anti join on file_id" pattern, because that simpler version silently skips failed files forever.

The retry path piggybacks on the existing `MERGE … WHEN MATCHED THEN UPDATE` in `mark_pending` / `mark_succeeded` ([F7.3](#f73-nb_update_control_table)) — a retry simply overwrites the failed row through `pending` → `succeeded`/`failed` on the next run. No schema migration, no separate "retry queue" table. Permanent skips use the `tombstoned` boolean.

Full operating playbook (manual one-off retry, bulk re-process after a fix, tombstoning corrupt files): [06-troubleshooting.md § 3.11](./06-troubleshooting.md#311-failed-files-are-not-retried-on-the-next-pipeline-run).

### A.5 Document Intelligence reaches Blob via the Foundry resource's MI

DI's `urlSource` parameter tells the service to **fetch the blob server-side** from the URL the notebook passes. Because the storage account has `allowSharedKeyAccess=false` and this pattern does not use SAS tokens, that fetch has to authenticate with a managed identity. In this pattern Document Intelligence is served by the **Microsoft Foundry resource** (`kind=AIServices`), so the identity used by DI is the **Foundry resource's system-assigned MI** — not a separate DI MI — and there is no key or token in the URL to fall back to.

The Bicep `rbac.bicep` module grants the **Foundry MI** **Storage Blob Data Reader** on the storage account automatically; manual deployments wire it in [03-deployment-manual.md § 1.7 step 3](./03-deployment-manual.md#17-rbac-wiring). Without this role, DI returns `InvalidContent: Could not download the file from the given URL` — see [06-troubleshooting.md § 3.9](./06-troubleshooting.md#39-document-intelligence-invalidcontent-could-not-download-the-file).

If the storage account firewall is locked down (private endpoints or `defaultAction: Deny`), the role grant alone isn't enough — the Foundry resource also needs a trusted-services bypass or a shared private endpoint. See [Managed identities for Document Intelligence — Private storage account access](https://learn.microsoft.com/azure/ai-services/document-intelligence/authentication/managed-identities#private-storage-account-access).

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
- [Refresh SQL Endpoint activity](https://learn.microsoft.com/fabric/data-factory/refresh-sql-endpoint-activity)
- [SQL analytics endpoint metadata sync](https://learn.microsoft.com/fabric/data-engineering/sql-analytics-endpoint-metadata-sync)
- [Web activity (Fabric) — connection-based, no inline MI/Resource fields](https://learn.microsoft.com/fabric/data-factory/web-activity)
- [Web v2 connector — auth supported in Dataflow Gen2 only, not pipelines](https://learn.microsoft.com/fabric/data-factory/connector-web-overview)
- [ADF/Fabric REST connector parity (no system-assigned MI in Fabric REST)](https://learn.microsoft.com/fabric/data-factory/connector-parity)
- [ForEach activity limitations and workarounds (ADF — applies to Fabric pipelines)](https://learn.microsoft.com/azure/data-factory/control-flow-for-each-activity#limitations-and-workarounds)
- [Nested activities in ADF / Fabric — embedding limitations](https://learn.microsoft.com/azure/data-factory/concepts-nested-activities#nested-activity-embedding-limitations)
- [Configure Azure Key Vault references (connection credentials)](https://learn.microsoft.com/fabric/data-factory/azure-key-vault-reference-configure)

**Notebook utilities**

- [NotebookUtils (former MSSparkUtils) for Fabric](https://learn.microsoft.com/fabric/data-engineering/notebook-utilities)
- [NotebookUtils credentials utilities](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials) (note: only 4 audience keys for `getToken`; `DefaultAzureCredential` not supported)
- [NotebookUtils notebook run and orchestration](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-notebook-run)
- [MSAL for Python](https://learn.microsoft.com/entra/msal/python/) (used by `nb_ocr_chunk_upload` to acquire the DI bearer token via the DI-caller service principal)

**Document Intelligence**

- [Azure AI Document Intelligence Python SDK (`azure-ai-documentintelligence`) reference](https://learn.microsoft.com/python/api/overview/azure/ai-documentintelligence-readme)
- [Document Intelligence prebuilt-read model](https://learn.microsoft.com/azure/ai-services/document-intelligence/prebuilt/read)
- [Managed identities for Document Intelligence](https://learn.microsoft.com/azure/ai-services/document-intelligence/authentication/managed-identities?view=doc-intel-4.0.0)

---

*Last updated: 2026-05-22*

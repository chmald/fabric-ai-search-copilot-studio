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
| Index has docs but `vectorIndexSize = 0` (Copilot Studio returns nothing; vector index size shows 0 B in the portal) | **Silent vectorizer failure** — most often the indexer has no skillset attached (vectors are never generated), or the AI Search MI has the wrong role on Foundry (`Cognitive Services User` instead of `Cognitive Services OpenAI User`) | [§4.1](#41-vectorizer-auth-failure-loud-or-silent) |
| Indexer status = `transientFailure` repeatedly | Integrated vectorizer auth failure (loud variant) | [§4.1](#41-vectorizer-auth-failure-loud-or-silent) |
| `403 Forbidden` from indexer reading Blob | Search MI missing Storage Blob Data Reader | [§4.2](#42-indexer-cannot-read-blob) |
| `401 Unauthorized` + `WWW-Authenticate: Bearer` from a REST call | API keys disabled — caller used `api-key` / `Ocp-Apim-Subscription-Key` instead of an Entra bearer token | [§0.1](#01-401-from-services-with-local-auth-disabled) |
| `403` from Storage with "KeyBasedAuthenticationNotPermitted" | Storage shared-key access disabled; caller used an account key or key-based connection string | [§0.2](#02-403-keybasedauthenticationnotpermitted-on-storage) |
| Bicep deploy fails on `search-deploy` with `BadRequest: AuthOptions must be null if DisableLocalAuth is true` | Search service body has both `authOptions` and `disableLocalAuth: true` — the API rejects this combination | [§0.4](#04-bicep-deploy-fails-authoptions-must-be-null-if-disablelocalauth-is-true) |
| Bicep deploy fails on `foundry-deploy` with `FlagMustBeSetForRestore: An existing resource ... has been soft-deleted` | The Foundry / Cognitive Services account name still exists in soft-deleted state from a prior deploy; ARM won't recreate without `restore: true` | [§0.5](#05-bicep-deploy-fails-flagmustbesetforrestore-soft-deleted-foundry--cognitive-services-account) |
| Copilot Studio knowledge source save fails with "key not valid" | Trying to use admin / query key on a service that has `disableLocalAuth=true` | [§5.7](#57-knowledge-source-save-fails-with-key-not-valid) |
| Agent works for the builder, but every other user gets "I don't have any information" / empty results | Knowledge source connection uses **Microsoft Entra ID Integrated** auth, which flows the **end-user** identity to AI Search; only users with **Search Index Data Reader** on the search service can retrieve | [§5.8](#58-agent-works-for-me-but-fails-for-other-users-or-i-had-to-add-search-index-data-reader-to-my-own-account) |
| Pipeline activity fails on OCR call | DI auth or wrong endpoint / API version | [§3.1](#31-document-intelligence-call-fails) |
| Pipeline chunk activity fails | Notebook auth or dependency missing | [§3.2](#32-chunking-notebook-fails) |
| Control table not updating | Notebook → Lakehouse permission issue | [§3.3](#33-control-table-stuck) |
| OneLake shortcut shows no files | Shortcut permissions or refresh lag | [§2](#2--onelake--source-attachment) |
| Cost spike | Fabric capacity left running, Foundry quota burned, indexer over-scheduled | [§6](#6--cost-and-quota) |

---

## 0 — Entra-only auth (local auth disabled)

This pattern provisions the **Microsoft Foundry resource** (which serves both Azure OpenAI deployments **and** the Document Intelligence `prebuilt-read` API — single multi-service Cognitive Services account, `kind=AIServices`) and **AI Search** with `disableLocalAuth=true`, and **Storage** with `allowSharedKeyAccess=false`. Most auth failures end up here.

### 0.1 401 from services with local auth disabled

**Symptom.** A REST call to AI Search / Document Intelligence / Foundry / Azure OpenAI returns `401 Unauthorized` and a `WWW-Authenticate: Bearer ...` header.

**Cause.** The caller sent an `api-key` (AI Search) or `Ocp-Apim-Subscription-Key` (Cognitive Services) header instead of `Authorization: Bearer <token>`, and the service rejects API keys because `disableLocalAuth=true`.

**Fix.** Replace the API-key header with a bearer token from the right resource scope:

| Target service | Token resource scope |
|---|---|
| AI Search | `https://search.azure.com/.default` |
| Document Intelligence / Foundry / Azure OpenAI | `https://cognitiveservices.azure.com/.default` |
| Storage (data plane) | `https://storage.azure.com/.default` |

Quick local test (PowerShell):

```pwsh
# AI Search
$TOKEN = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv
curl.exe -H "Authorization: Bearer $TOKEN" `
  'https://<svc>.search.windows.net/indexes/idx-rag-documents/docs/$count?api-version=2024-07-01'

# Document Intelligence (served by the Foundry resource)
$TOKEN = az account get-access-token --resource https://cognitiveservices.azure.com --query accessToken -o tsv
curl.exe -H "Authorization: Bearer $TOKEN" `
  "https://<foundry>.cognitiveservices.azure.com/documentintelligence/info?api-version=2024-11-30"
```

If the bearer call also returns 401/403, the caller's identity is missing the required RBAC role — see [02-prerequisites.md § 10](./02-prerequisites.md#10--rbac-role-assignments-cheat-sheet) for the canonical role list.

### 0.2 403 KeyBasedAuthenticationNotPermitted on Storage

**Symptom.** A call to Blob (e.g. from `az storage blob upload`, an old SDK call with `--account-key`, an indexer datasource with an `AccountKey=...` connection string) fails with `403 KeyBasedAuthenticationNotPermitted`.

**Cause.** The storage account has `allowSharedKeyAccess: false`. Account keys and key-based connection strings are rejected.

**Fix.** Pick the auth that matches the caller:

- **Azure CLI / interactive:** add `--auth-mode login` to `az storage` commands.
- **AI Search datasource:** use `"connectionString": "ResourceId=/subscriptions/.../storageAccounts/<st>;"` — the indexer authenticates with its system-assigned MI (Storage Blob Data Reader required).
- **Document Intelligence `urlSource`:** DI must authenticate to Blob via a managed identity with Storage Blob Data Reader on the account. DI is served by the Foundry resource in this pattern, so the identity is the **Foundry MI**. The request is then a plain `https://<st>.blob.core.windows.net/raw/<file>` URL without a SAS.
- **Fabric pipeline Copy activity:** the Blob connection must use **Organizational account** or **Service principal** auth, not **Account key**; the runtime identity (workspace identity or SP) needs Storage Blob Data Contributor.
- **App code:** swap `BlobServiceClient(account_url, credential=AzureKeyCredential(key))` for `BlobServiceClient(account_url, credential=DefaultAzureCredential())`.

### 0.3 Bicep deploy fails: "RoleAssignmentExists" or "AuthorizationFailed" on rbac module

**Symptom.** First `az deployment sub create` after enabling `deployerPrincipalId` succeeds; second run fails on `rbac-deploy` with `RoleAssignmentExists`.

**Cause.** The role-assignment resource uses a deterministic GUID derived from `(scope, principalId, roleDefinitionId)`. Re-running Bicep tries to create the same assignment, which is fine — but if the principal was previously assigned the role via a different mechanism (e.g. via `az role assignment create` with a fresh GUID), the deterministic-GUID assignment may conflict.

**Fix.**

- Remove the pre-existing manual assignment: `az role assignment delete --assignee <obj-id> --role "Search Service Contributor" --scope <svc-id>`
- Re-deploy. The Bicep-managed assignment will land cleanly.

If the failure is `AuthorizationFailed`, the deploying identity lacks **User Access Administrator** on the resource group — see [02-prerequisites.md § 1](./02-prerequisites.md#1--azure-subscription).

### 0.4 Bicep deploy fails: `AuthOptions must be null if DisableLocalAuth is true`

**Symptom.** `az deployment sub create` (or `pwsh ./infra/deploy.ps1`) fails on the `search-deploy` nested deployment with:

```
ResourceDeploymentFailure
  search-deploy
    BadRequest: AuthOptions must be null if DisableLocalAuth is true.
```

**Cause.** The Azure AI Search resource (`Microsoft.Search/searchServices`) treats `properties.authOptions` and `properties.disableLocalAuth: true` as **mutually exclusive**. When local auth is disabled, all API keys are rejected and every caller must use an Entra bearer token — there is no meaningful "auth options" to configure, so the body must omit (or null-out) `authOptions` entirely. Setting both fields is rejected at validation time before any resource changes are applied.

A common historical mistake is to carry over CLI / ARM examples that include:

```jsonc
"properties": {
  "authOptions": { "aadOrApiKey": { "aadAuthFailureMode": "http401WithBearerChallenge" } },
  "disableLocalAuth": true
}
```

… thinking `authOptions` is needed to opt into the bearer challenge. It isn't. When `disableLocalAuth: true`, the service issues a `401 Unauthorized` with `WWW-Authenticate: Bearer ...` by default for every unauthenticated request.

**Fix — Bicep.** Remove the `authOptions` block from `infra/modules/search.bicep`:

```bicep
resource search 'Microsoft.Search/searchServices@2024-03-01-preview' = {
  properties: {
    // ...
    // DO NOT set authOptions when disableLocalAuth is true
    disableLocalAuth: true
  }
}
```

**Fix — az CLI (manual deploy path § 1.6).** Do not pass `--auth-options` together with `--disable-local-auth true`:

```pwsh
# WRONG — returns BadRequest: AuthOptions must be null if DisableLocalAuth is true
az search service update --name <svc> --resource-group <rg> `
  --auth-options aadOrApiKey `
  --aad-auth-failure-mode http401WithBearerChallenge `
  --disable-local-auth true

# CORRECT
az search service update --name <svc> --resource-group <rg> `
  --disable-local-auth true
```

**Verify after fix.** The deployment redeploys cleanly, and any unauthenticated request to the service returns the proper bearer challenge automatically:

```pwsh
curl.exe -i "https://<svc>.search.windows.net/indexes?api-version=2024-07-01"
# HTTP/1.1 401 Unauthorized
# WWW-Authenticate: Bearer authorization_uri="https://login.microsoftonline.com/...", ...
```

### 0.5 Bicep deploy fails: `FlagMustBeSetForRestore` (soft-deleted Foundry / Cognitive Services account)

**Symptom.** `az deployment sub create` (or `pwsh ./infra/deploy.ps1`) fails on the `foundry-deploy` nested deployment with:

```
InvalidTemplateDeployment - The template deployment 'main' is not valid according to
the validation procedure. The following resource provider(s) -
'Microsoft.CognitiveServices/accounts (2024-10-01)' reported preflight validation errors.
FlagMustBeSetForRestore - An existing resource with ID
'/subscriptions/.../providers/Microsoft.CognitiveServices/accounts/aif-...' has been
soft-deleted. To restore the resource, you must specify 'restore' to be 'true' in the
property. If you don't want to restore existing resource, please purge it first.
```

**Cause.** Cognitive Services accounts (Foundry / OpenAI / Document Intelligence / Vision / Speech / Translator) have a **48-hour soft-delete retention window** on the account *name*. If the account was deleted (manually, by a teardown script, or by a failed deployment rollback) within the last 48 hours, ARM blocks a fresh create with the same name until the operator explicitly chooses to either:

- **restore in place** (preserves the system-assigned MI principal ID and all data-plane state), or
- **purge** (drops the soft-deleted account entirely so a brand-new resource can be created with a new MI).

**Preserving the MI matters specifically because the DI-caller SP's `Cognitive Services User` role assignment on the Foundry resource is granted manually ([03b-fabric-setup.md § F2.2 step 2](./03b-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook)) and would be orphaned by any purge-and-recreate cycle.**

#### Fix — restore in place (recommended)

This pattern's Bicep exposes an opt-in `restoreFoundryFromSoftDelete` parameter exactly for this scenario. `infra/modules/aifoundry.bicep` conditionally adds `properties.restore: true` only when this param is true, so it is **safe by default** (a healthy / fresh deploy does **not** carry the `restore` flag).

> **Why isn't `restore: true` always on?** The Cognitive Services ARM provider rejects `restore: true` on a fresh create with `CanNotRestoreANonExistingResource: Could not locate a resource to restore.` It is therefore not safe to leave the flag permanently in the template body — it must be set per-deploy only when the operator knows a soft-deleted ghost exists.

**Recover with `deploy.ps1`** (recommended):

```pwsh
# Use the -RestoreFoundry switch to add restoreFoundryFromSoftDelete=true to the Bicep params
pwsh ./infra/deploy.ps1 -RestoreFoundry
```

**Recover with raw `az` CLI**:

```pwsh
az deployment sub create `
  --name rag-kb-bicep-restore `
  --location <region> `
  --template-file infra/main.bicep `
  --parameters infra/main.parameters.local.json `
  --parameters restoreFoundryFromSoftDelete=true
```

After the recovery deploy succeeds, **drop the switch / parameter** on subsequent deploys (`pwsh ./infra/deploy.ps1` with no `-RestoreFoundry`). Leaving it on would cause every future deploy to fail with `CanNotRestoreANonExistingResource` because there is no longer a soft-deleted resource to restore from.

#### Alternative — purge and let Bicep create fresh

Use this only when you intentionally want a clean-slate Foundry resource (new MI, all role assignments need re-wiring):

```pwsh
az cognitiveservices account purge `
  --name aif-rag-<env>-<region> `
  --resource-group rg-rag-<env>-<region> `
  --location <region>
```

Then `pwsh ./infra/deploy.ps1` (no switch). After the deploy:

1. Bicep's deterministic role assignments (AI Search MI → Cognitive Services OpenAI User on Foundry, Foundry MI → Storage Blob Data Reader on Storage) recreate themselves with the new MI principal ID.
2. **You must manually re-grant the DI-caller SP role** — the SP's `Cognitive Services User` on the *old* Foundry resource is orphaned. Re-run [03b-fabric-setup.md § F2.2 step 2](./03b-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook) against the new Foundry resource.
3. Wait up to **15 minutes** for role propagation before the Fabric pipeline can call DI again.

#### Verify after fix

```pwsh
# Confirm the account is in 'Succeeded' provisioning state and the MI is populated
az cognitiveservices account show --name aif-rag-<env>-<region> -g rg-rag-<env>-<region> `
  --query "{state:properties.provisioningState, mi:identity.principalId}" -o json

# Confirm no soft-deleted ghost exists with the same name in the region
az cognitiveservices account list-deleted --query "[?name=='aif-rag-<env>-<region>']" -o table
```

Reference: [Recover or purge deleted Azure AI Services resources](https://learn.microsoft.com/azure/ai-services/recover-purge-resources).

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

**Symptom.** The OCR step in `nb_ocr_chunk_upload` (which calls the Document Intelligence `prebuilt-read` model on the Microsoft Foundry resource) returns 401 / 403 / 404 / 500. This pattern uses a Fabric **notebook** — not a pipeline Web activity — to call DI; see [03b-fabric-setup.md Appendix A.1](./03b-fabric-setup.md#a1-no-web-activity-until-or-child-pipeline) for the rationale.

| Status | Common cause | Fix |
|---|---|---|
| 401 (with `WWW-Authenticate: Bearer`) | Local auth is disabled on the Foundry resource (which serves DI); the caller used an `Ocp-Apim-Subscription-Key` header instead of a bearer token. | `nb_ocr_chunk_upload` uses MSAL + the DI-caller service principal (secret fetched from Key Vault by the workspace identity) to get a bearer token for `https://cognitiveservices.azure.com/.default`. See [03b-fabric-setup.md § F7.2](./03b-fabric-setup.md#f72-nb_ocr_chunk_upload) and [§ 3.7](#37-nb_ocr_chunk_upload-cant-authenticate-to-document-intelligence). Fabric notebooks don't support `DefaultAzureCredential` and `notebookutils.credentials.getToken` has no `cognitiveservices` audience key — hence the MSAL+SP detour. |
| 403 (from DI) | The DI-caller service principal (`sp-rag-di-caller`) lacks **Cognitive Services User** on the Foundry resource. The Fabric workspace identity is *not* used for DI calls in this pattern. | Grant the role per [03b-fabric-setup.md § F2.2 step 2](./03b-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook); wait up to 15 min for propagation |
| 403 (from DI fetching `urlSource`) | The Foundry MI lacks **Storage Blob Data Reader** on the storage account; required because shared-key access on Storage is disabled | Grant the role per [03-deployment-manual.md § 1.7 step 3](./03-deployment-manual.md#17-rbac-wiring) (Bicep deployments wire this automatically via `rbac.bicep`) |
| 404 | Wrong URL or model name | Confirm endpoint is the Foundry resource's `https://<foundry>.cognitiveservices.azure.com/documentintelligence/...` host (not `<foundry>.openai.azure.com`) and uses `prebuilt-read` |
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

### 3.3.1 `nb_update_control_table` fails with `PySparkValueError: CANNOT_DETERMINE_TYPE`

**Symptom.** The `mark_pending` (or `mark_succeeded` / `mark_failed`) notebook activity fails with:

```
Notebook execution failed at Notebook service with http status code - '200',
please check the Run logs on Notebook, additional details -
'Error name - PySparkValueError, Error value -
[CANNOT_DETERMINE_TYPE] Some of types cannot be determined after inferring.'
```

**Cause.** `nb_update_control_table` was building its single-row DataFrame with `spark.createDataFrame([(...)], [<column-names>])` and letting PySpark infer the schema. For `mark_pending`, most numeric and timestamp columns are `None` (no `chunk_count`, `page_count`, `ocr_completed_ts`, `chunk_completed_ts`, `last_error` yet), and Spark cannot determine column types from a row of nulls.

Compounded by: Fabric pipeline base parameters arrive at the notebook as **strings** by default, so `byte_size` and `source_modified_ts` are string-typed when they hit `createDataFrame`, conflicting with the Delta table's `LongType` / `TimestampType`.

**Fix.** Pull the schema from the existing `control_table_files` Delta table and pass it explicitly to `createDataFrame`, and coerce string parameters into proper int / datetime values first. The current [F7.3 `nb_update_control_table`](./03b-fabric-setup.md#f73-nb_update_control_table) reflects this fix — copy that cell wholesale into the notebook. Key fragment:

```python
from datetime import datetime, timezone

def _coerce_int(v):
    if v is None or v == "" or v == "None":
        return None
    return int(v)

def _coerce_ts(v):
    if v is None or v == "" or v == "None":
        return None
    if isinstance(v, datetime):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None

# Pull the schema from the table so Spark doesn't try to infer it from a mostly-None row
schema = spark.table("control_table_files").schema
row = spark.createDataFrame([row_tuple], schema)
```

After re-saving the notebook, re-run the failed pipeline.

### 3.4 Pipeline runs duplicate files

**Symptom.** Each pipeline run re-processes files it has already processed.

**Cause.** `file_id` hash is not stable — typically because `source_modified_ts` is included but the upstream source updates it on every read (some storage tiers do this).

**Fix.** Switch the hash input to `(source_path, byte_size, content_md5)` if available. As a last resort, hash the file content (slower).

### 3.5 Copy activity fails with `PathNotFound` and an `abfss:/...` URI in the path

**Symptom.** The `copy_raw_to_blob` activity inside the ForEach fails with:

```
ErrorCode=UserErrorFileNotFound,...Lakehouse operation failed for: Operation returned an invalid status code 'NotFound'.
Workspace: '<workspaceId>'.
Path: '<lakehouseId>/Files/abfss:/<workspaceId>@onelake.dfs.fabric.microsoft.com/<lakehouseId>/Files/source_docs/<filename>'.
ErrorCode: 'PathNotFound'.
```

Notice the path contains `Files/abfss:/...` — the abfss URI has been appended to the Lakehouse root instead of being used directly.

**Cause.** `nb_lookup_new_files` is writing **absolute abfss URIs** into `_tmp_new_files.source_path`. Spark's `binaryFile` reader populates `path` with the full URI (`abfss://<workspaceId>@onelake.dfs.fabric.microsoft.com/<lakehouseId>/Files/source_docs/<file>`), but the pipeline Copy activity treats `@item().source_path` as a path **relative to its Lakehouse `Files/` Root folder**. Result: the activity asks the Lakehouse for `<lakehouseId>/Files/<entire-abfss-uri>`, which 404s.

**Fix.** Strip the abfss prefix in the lookup notebook so `source_path` is relative to `Files/`:

```python
from pyspark.sql.functions import regexp_replace

src = src.withColumn(
    "source_path",
    regexp_replace(col("source_path"), r"^.*/Files/", ""),
)
```

This collapses values like `abfss://.../<lakehouseId>/Files/source_docs/x.pdf` to just `source_docs/x.pdf`. See [03b-fabric-setup.md § F7.1](./03b-fabric-setup.md#f71-nb_lookup_new_files) for the full notebook. After applying the fix, re-run `nb_lookup_new_files` (or the whole pipeline) so `_tmp_new_files` is rewritten with the corrected paths.

**Verify** in the SQL analytics endpoint:

```sql
SELECT source_path FROM _tmp_new_files LIMIT 5;
-- Should show e.g. 'source_docs/NDA-001.pdf', NOT 'abfss://...@onelake.dfs.fabric.microsoft.com/.../Files/source_docs/NDA-001.pdf'
```

### 3.6 Lookup activity returns zero rows after a Spark write

**Symptom.** First pipeline run: `nb_lookup_new_files` reports `new_count = 5` in its exit value, but the next `lookup_new_files_rows` Lookup activity returns `value: []` (zero rows). The ForEach iterates zero times. On the **second** pipeline run a few minutes later, the same Lookup suddenly returns the 5 rows from the first run.

**Cause.** `nb_lookup_new_files` writes `_tmp_new_files` via Spark to the Lakehouse Delta store. The Lookup activity reads from the same lakehouse but via its **SQL analytics endpoint**, which syncs Delta metadata via a [background process](https://learn.microsoft.com/fabric/data-engineering/sql-analytics-endpoint-metadata-sync). The sync can lag seconds to minutes behind the Spark write, so an immediate downstream Lookup misses the freshly written rows.

**Fix.** Insert a [Refresh SQL Endpoint activity](https://learn.microsoft.com/fabric/data-factory/refresh-sql-endpoint-activity) between the lookup notebook and the Lookup activity. See [03b-fabric-setup.md § F8.2](./03b-fabric-setup.md#f82-activity-15--refresh-sql-endpoint).

The activity returns `Success` after a sync, or `NotRun` if there's nothing to sync since the last refresh (both are OK). A `Failure` outcome under lock contention is a [known issue](https://learn.microsoft.com/fabric/data-factory/refresh-sql-endpoint-activity#why-does-my-sql-endpoint-refresh-fail-when-underlying-data-is-locked) — but in our case the lookup notebook has already finished and released its writer locks by the time this activity runs, so contention is rare.

### 3.7 `nb_ocr_chunk_upload` can't authenticate to Document Intelligence

**Symptom.** One of:

- `ImportError: cannot import name 'DefaultAzureCredential' from 'azure.identity'`, or the constructor hangs / fails at runtime
- Authentication errors against Document Intelligence (`ClientAuthenticationError`, `401 Unauthorized`, "managed identity not found")
- `notebookutils.credentials.getToken('cognitiveservices')` (or `'https://cognitiveservices.azure.com/'`) raises "unsupported audience"

**Cause.** Per the Microsoft Learn [NotebookUtils credentials docs](https://learn.microsoft.com/fabric/data-engineering/notebookutils/notebookutils-credentials#get-token):

> "Fabric notebooks don't support `DefaultAzureCredential` directly."

And `notebookutils.credentials.getToken` exposes only **four** audience keys: `storage`, `pbi`, `keyvault`, `kusto`. There is no key for Cognitive Services (the audience needed to call Document Intelligence). The Fabric workspace identity also doesn't expose its client secret, so MSAL with the workspace identity isn't possible either.

**Fix.** Use the MSAL + DI-caller service principal pattern documented in [03b-fabric-setup.md § F7.2](./03b-fabric-setup.md#f72-nb_ocr_chunk_upload) and [F2.2](./03b-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook):

1. Create a dedicated service principal (`sp-rag-di-caller`) and grant it **Cognitive Services User** on the **Foundry resource** (which serves the Document Intelligence endpoint in this pattern — no separate FormRecognizer account is provisioned).
2. Store the SP's client secret in Key Vault under `di-sp-secret`.
3. Grant the Fabric workspace identity **Key Vault Secrets User** on the Key Vault.
4. In the notebook, read the SP secret via `notebookutils.credentials.getSecret(kv_uri, 'di-sp-secret')`, then use MSAL `ConfidentialClientApplication.acquire_token_for_client()` with scope `https://cognitiveservices.azure.com/.default` to get a DI bearer token.
5. Wrap that token in a small `TokenCredential` adapter and pass to `DocumentIntelligenceClient(endpoint=..., credential=adapter)`.

For Blob access from the same notebook, wrap `notebookutils.credentials.getToken('storage')` in the same `TokenCredential` adapter — workspace identity works there because `storage` IS one of the four supported audience keys.

### 3.8 `%pip install` fails with `MagicUsageError: %pip magic command is disabled`

**Symptom.** `ocr_chunk_upload` (or any notebook activity that uses `%pip install`) fails in a pipeline run with:

```
Notebook execution failed at Notebook service with http status code - '200',
please check the Run logs on Notebook, additional details -
'Error name - MagicUsageError, Error value - %pip magic command is disabled.
Find more details in https://learn.microsoft.com/en-us/fabric/data-engineering/library-management#inline-installation'
```

The same notebook **runs fine interactively** from the notebook editor — the failure is pipeline-specific.

**Cause.** Per [Manage Apache Spark libraries in Microsoft Fabric](https://learn.microsoft.com/fabric/data-engineering/library-management#inline-installation):

> "Inline commands for managing Python libraries are disabled in notebook pipeline runs by default."

Fabric blocks `%pip install` in non-interactive runs because per-run dependency resolution can produce inconsistent dependency trees across runs.

**Fix.** Choose based on your maturity:

**Option A — Quick fix (suitable for demos / dev).** Pass `_inlineInstallationEnabled = true` as a **base parameter** on the notebook activity in the pipeline. This re-enables `%pip` for that specific activity.

- Open `pl_ingest_docs` → select the `ocr_chunk_upload` Notebook activity → **Settings → Base parameters** → add: `_inlineInstallationEnabled` (type: Boolean) = `true`
- Save and re-run the pipeline

**Option B — Fabric Environment (recommended for production).** Move the library list out of the notebook entirely:

1. In your Fabric workspace, **+ New item → Environment** → name `env-rag-<env>`.
2. **Libraries → Public libraries** → add: `azure-ai-documentintelligence==1.0.0`, `azure-storage-blob==12.21.0`, `azure-core==1.30.2`, `msal==1.30.0`, `tiktoken==0.7.0`.
3. **Publish** in **Full mode** (3–6 min publish; adds 1–3 min to session startup, but eliminates per-run variance — see [environment publishing modes](https://learn.microsoft.com/fabric/data-engineering/library-management#environment-publishing-modes-quick-vs-full)).
4. Open `nb_ocr_chunk_upload` → ribbon **Environment** dropdown → select `env-rag-<env>`.
5. **Delete the `%pip install` cell** from the notebook — the libraries are now loaded by Fabric at session start.
6. Remove `_inlineInstallationEnabled` from the notebook activity base parameters if you added it for Option A.

For mixed scenarios (some notebooks need different libraries), see [Manage libraries in Fabric environments](https://learn.microsoft.com/fabric/data-engineering/environment-manage-library).

### 3.9 Document Intelligence `InvalidContent: Could not download the file`

**Symptom.** `ocr_chunk_upload` fails with:

```
HttpResponseError, Error value -
(InvalidRequest) Invalid request.
Code: InvalidRequest
Message: Invalid request.
Inner error: {
    "code": "InvalidContent",
    "message": "Could not download the file from the given URL."
}
```

**Cause.** Document Intelligence tried to fetch `urlSource` (the `https://<storage>.blob.core.windows.net/raw/<file_id>/<filename>` URL the notebook passed) and got rejected. With shared-key access disabled on the storage account (`allowSharedKeyAccess: false`), DI must authenticate to Blob via a managed identity — specifically the Foundry resource's system-assigned MI (DI runs inside the Foundry account). If that MI lacks **Storage Blob Data Reader** on the storage account, storage returns 401/403 and DI surfaces it as `InvalidContent`.

(Other less common causes: the blob doesn't exist at the URL the notebook constructed; the storage firewall blocks the Foundry resource; the Foundry MI is disabled.)

**Diagnostic flow.** Run these checks against your environment (replace `<sub>`, `<rg>`, `<foundry>`, `<storage>` with values from `demo-ids.local.json`):

```pwsh
# 1. Confirm the Foundry resource (which serves DI) has a system-assigned MI and capture its principal ID
$AIF_OBJID = az cognitiveservices account show --name <foundry> -g <rg> `
  --query identity.principalId -o tsv
Write-Host "Foundry MI: $AIF_OBJID"

# 2. Confirm shared-key is disabled on Storage (this pattern's default)
az storage account show --name <storage> `
  --query "{allowSharedKeyAccess:allowSharedKeyAccess, bypass:networkRuleSet.bypass}" -o json

# 3. Check whether the Foundry MI has any role on the storage account
$ST_RES_ID = az storage account show --name <storage> -g <rg> --query id -o tsv
az role assignment list --assignee $AIF_OBJID --scope $ST_RES_ID -o table

# 4. Confirm the blob actually exists (sign in as your az identity, which has
#    Storage Blob Data Contributor from Phase 1.7)
az storage blob list --account-name <storage> --container-name raw `
  --auth-mode login --query "[].name" -o tsv
```

If step 3 returns no rows, that's the cause.

**Fix.** Grant Storage Blob Data Reader to the Foundry MI:

```pwsh
$AIF_OBJID = az cognitiveservices account show --name <foundry> -g <rg> --query identity.principalId -o tsv
$ST_RES_ID = az storage account show --name <storage> -g <rg> --query id -o tsv

az role assignment create `
  --assignee-object-id $AIF_OBJID --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Reader" `
  --scope $ST_RES_ID
```

Wait **5–15 minutes** for the role to propagate, then re-run the pipeline.

If you originally provisioned via `infra/main.bicep` and this assignment is missing, your deployment predates the DI-consolidation fix — pull latest and re-run `pwsh ./infra/deploy.ps1` (the `rbac.bicep` module now grants Storage Blob Data Reader to the Foundry MI automatically; see [03-deployment-manual.md § 1.7 step 3](./03-deployment-manual.md#17-rbac-wiring)).

**If you're running with the storage firewall locked down** (private endpoints, or `defaultAction: Deny`), the role grant alone isn't sufficient — the Foundry resource needs either a [trusted-services bypass](https://learn.microsoft.com/azure/storage/common/storage-network-security#grant-access-to-trusted-azure-services) on the storage account or a shared private endpoint. See [Managed identities for Document Intelligence — Private storage account access](https://learn.microsoft.com/azure/ai-services/document-intelligence/authentication/managed-identities#private-storage-account-access).

### 3.10 PyJWT dependency-conflict warning

**Symptom.** During `%pip install` in `nb_ocr_chunk_upload`, pip prints:

```
ERROR: pip's dependency resolver does not currently take into account all the packages
that are installed. This behaviour is the source of the following dependency conflicts.
fsspec-wrapper 0.1.15 requires PyJWT>=2.6.0, but you have pyjwt 2.4.0 which is incompatible.
```

The notebook **still runs**, but the conflict can cause subtle import / runtime issues later.

**Cause.** `msal` declares a loose PyJWT constraint (`pyjwt[crypto]>=1.0.0,<3`), so pip's resolver picks an older version (`2.4.0`) than Fabric's preinstalled `fsspec-wrapper` requires (`>=2.6.0`).

**Fix.** Pin `pyjwt>=2.6.0` explicitly in the install line:

```python
%pip install azure-ai-documentintelligence==1.0.0 azure-storage-blob==12.21.0 \
             azure-core==1.30.2 msal==1.30.0 "pyjwt>=2.6.0" tiktoken==0.7.0 --quiet
```

The current [F7.2 `nb_ocr_chunk_upload`](./03b-fabric-setup.md#f72-nb_ocr_chunk_upload) reflects this fix.

If you've moved to the Fabric Environment pattern from [§ 3.8 Option B](#38-pip-install-fails-with-magicusageerror-pip-magic-command-is-disabled), add `pyjwt>=2.6.0` to the Environment's public-libraries list as well so the Full-mode dependency resolution picks the right version.

### 3.11 Failed files are not retried on the next pipeline run

**Symptom.** A file shows up in `control_table_files` with `ocr_status = 'failed'` (or `chunk_status` / `index_status` = `'failed'`). You re-run `pl_ingest_docs` and the lookup activity reports `new_count: 0` — the failed file is **not** picked up.

**Cause.** Older versions of `nb_lookup_new_files` used a plain `left_anti` join against `control_table_files`, which excludes **every** row already in the control table — including failed ones. The current notebook ([F7.1](./03b-fabric-setup.md#f71-nb_lookup_new_files)) was updated to also pick up rows where any per-stage status is `'failed'` (gated by `tombstoned`).

**Fix — update the lookup notebook.** Open `nb_lookup_new_files` and confirm it contains the union pattern (brand-new + retry):

```python
from pyspark.sql.functions import col, lit

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
to_process  = brand_new.unionByName(retry_files).dropDuplicates(["file_id"])
```

The downstream `mark_pending` activity already does `MERGE … WHEN MATCHED THEN UPDATE`, so the retry simply overwrites the failed row with `pending` at the start of the run and `succeeded`/`failed` at the end — no manual cleanup needed.

**Inspect the control table** to see what's failed and why:

```sql
-- SQL analytics endpoint of lh_rag_<env>
SELECT file_id, source_path, ocr_status, chunk_status, index_status,
       last_error, ingest_ts, tombstoned
FROM control_table_files
WHERE ocr_status   = 'failed'
   OR chunk_status = 'failed'
   OR index_status = 'failed'
ORDER BY ingest_ts DESC;
```

**Force a single file to be re-tried** without re-running the whole pipeline — set any stage to `'failed'` (or clear the row):

```sql
-- Option A: mark a specific stage as failed → next run will retry
UPDATE control_table_files
SET   ocr_status   = 'failed',
      last_error   = 'manual retry trigger'
WHERE file_id = '<file_id>';

-- Option B: delete the row → next run treats the file as brand new
DELETE FROM control_table_files WHERE file_id = '<file_id>';
```

> **Caveat:** SQL DML against lakehouse tables runs in the **SQL analytics endpoint** (read-only by default in some Fabric tenant configurations). If `UPDATE` / `DELETE` is blocked, run the equivalent operation in a notebook attached to the lakehouse:
>
> ```python
> from delta.tables import DeltaTable
> DeltaTable.forName(spark, "control_table_files").update(
>     condition = "file_id = '<file_id>'",
>     set       = {"ocr_status": "'failed'", "last_error": "'manual retry trigger'"},
> )
> ```

**Permanently skip a file** (corrupt PDF, scanned image DI can't read, intentionally excluded document) — tombstone it:

```sql
UPDATE control_table_files SET tombstoned = true WHERE file_id = '<file_id>';
```

Tombstoned rows are excluded from both the new-file and retry passes of `nb_lookup_new_files`, so they will never be processed again until you flip the flag back. They remain in the table for audit / reporting.

**Re-process every failed file in bulk** after a known-fixed regression (e.g. you just granted the missing RBAC role from [§ 3.9](#39-document-intelligence-invalidcontent-could-not-download-the-file)):

```sql
-- No-op if your nb_lookup_new_files already includes the retry union
-- (this just demonstrates that the failed rows are still in scope)
SELECT COUNT(*) AS retryable
FROM control_table_files
WHERE (ocr_status = 'failed' OR chunk_status = 'failed' OR index_status = 'failed')
  AND (tombstoned IS NULL OR tombstoned = false);
```

Then trigger `pl_ingest_docs` — the lookup activity's exit payload will report `retry_count` matching this query.

---

## 4 — AI Search index / indexer

### 4.1 Vectorizer auth failure (loud OR silent)

**Symptom — loud variant.** Indexer status shows `lastResult.errorMessage` referencing OpenAI 401 / 403 from the Foundry endpoint, or "managed identity not authorized to invoke embedding deployment."

**Symptom — silent variant (more common, harder to diagnose).** Indexer reports `status: success` and a non-zero `documentCount`, but:

- AI Search service stats show `vectorIndexSize.usage = 0` while `documentCount.usage > 0`
- Documents returned by a `*` search have a `content_vector` field that is `null` or an empty array
- Copilot Studio / your client app sends a vector-first query and gets back zero hits — "I don't have information." — even though the index is populated with text

The indexer's overall `success` status hides the failure entirely — there's no error, no warning, no telltale `transientFailure`. The chunks are committed text-only with a null vector.

**Quick diagnostic.** Hit the service-stats endpoint — if `vectorIndexSize: 0` while `documentCount: N>0`, you're looking at silent vectorizer failure:

```pwsh
$TOKEN = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv
Invoke-RestMethod `
  -Uri "https://<search-svc>.search.windows.net/servicestats?api-version=2024-07-01" `
  -Headers @{ Authorization = "Bearer $TOKEN" } `
  | Select-Object -ExpandProperty counters `
  | Select-Object documentCount, vectorIndexSize, storageSize
```

**Cause — in order of likelihood:**

1. **No skillset attached to the indexer** (most common). The `azureOpenAI` *vectorizer* on the index is **query-time only** — it converts incoming text queries to vectors at search time. To generate vectors at INDEX time you need a separate **skillset** with an `AzureOpenAIEmbeddingSkill`, with the indexer referencing it via `skillsetName` and writing the skill's output into `content_vector` via `outputFieldMappings`. If the indexer has `skillsetName: null` or `outputFieldMappings: []`, this is the cause.

2. **Wrong role on the AI Search MI**. The required role on the Foundry resource is **`Cognitive Services OpenAI User`** (role ID `5e0bd9bd-7b93-4f28-af87-19fc36ad61bd`). The similarly named **`Cognitive Services User`** (role ID `a97b65f3-24c7-4388-baec-2e87135dc908`) grants data-plane access to non-OpenAI Cognitive Services (Document Intelligence, Translator, Vision) on a Foundry/AIServices resource but **does NOT** grant the OpenAI sub-namespace required for embedding / completion calls. Both cases produce identical silent-failure symptoms.

3. **Missing role entirely** — same symptom as #2 above; the skill call gets 401/403 and the indexer silently swallows it.

See [Azure OpenAI vectorizer reference — vectorizer parameters](https://learn.microsoft.com/azure/search/vector-search-vectorizer-azure-open-ai#vectorizer-parameters) and the [Azure OpenAI embedding skill](https://learn.microsoft.com/azure/search/cognitive-search-skill-azure-openai-embedding) docs.

**Verify configuration.** Run these against your environment to nail down which of the three causes you're hitting:

```pwsh
$SEARCH = "<search-svc-name>"
$TOKEN  = az account get-access-token --resource https://search.azure.com --query accessToken -o tsv
$headers = @{ Authorization = "Bearer $TOKEN" }

# 1. Is a skillset attached to the indexer?
Invoke-RestMethod -Uri "https://$SEARCH.search.windows.net/indexers/<indexer-name>?api-version=2024-07-01" -Headers $headers `
  | Select-Object skillsetName, outputFieldMappings
# Expected:
#   skillsetName: "skill-rag-embeddings"
#   outputFieldMappings includes a mapping to "content_vector"
# If skillsetName is null — cause #1. Skip to Fix § A.

# 2. Does the skillset exist?
(Invoke-RestMethod -Uri "https://$SEARCH.search.windows.net/skillsets?api-version=2024-07-01" -Headers $headers).value `
  | Select-Object -ExpandProperty name

# 3. What role does the AI Search MI have on Foundry?
$SEARCH_OBJID = "<AI Search system-assigned MI object ID>"
$AIF_RES_ID   = az cognitiveservices account show --name <foundry-resource> -g <rg> --query id -o tsv
az role assignment list --scope $AIF_RES_ID --fill-principal-name false `
  --query "[?principalId=='$SEARCH_OBJID'].{role:roleDefinitionName}" -o table
# Expected: Cognitive Services OpenAI User
# If "Cognitive Services User" or nothing — cause #2 or #3. Skip to Fix § B.
```

**Fix A — missing skillset (cause #1).** Create the skillset + update the indexer to reference it:

```pwsh
# Create the AzureOpenAIEmbeddingSkill skillset
$skillsetBody = @{
    name = "skill-rag-embeddings"
    skills = @(@{
        "@odata.type" = "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill"
        name          = "embed-content"
        context       = "/document"
        resourceUri   = "https://<foundry-resource>.openai.azure.com"
        deploymentId  = "embedding"
        modelName     = "text-embedding-3-large"
        dimensions    = 3072
        inputs        = @(@{ name = "text"; source = "/document/content" })
        outputs       = @(@{ name = "embedding"; targetName = "content_vector_embedding" })
    })
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Put `
  -Uri "https://$SEARCH.search.windows.net/skillsets/skill-rag-embeddings?api-version=2024-07-01" `
  -Headers @{ Authorization = "Bearer $TOKEN"; "Content-Type" = "application/json" } `
  -Body $skillsetBody

# Re-PUT the indexer with skillsetName + outputFieldMappings
# (Get the current indexer with GET first, then add these two fields; PUT replaces the whole resource.)
# Or just re-run the post-deploy script:
python scripts/post_deploy_search.py --ids demo-ids.local.json --run-indexer
```

For the manual portal walkthrough, see [03-deployment-manual.md § 4.3](./03-deployment-manual.md#43-create-the-skillset-indexing-time-vectorization).

**Fix B — wrong / missing role (causes #2 and #3).** Apply the right role:

```pwsh
az role assignment create `
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal `
  --role "Cognitive Services OpenAI User" `
  --scope $AIF_RES_ID

# (Optional) remove the misleading non-OpenAI role to keep the principal clean:
# az role assignment delete --assignee $SEARCH_OBJID --role "Cognitive Services User" --scope $AIF_RES_ID
```

**After either fix — force re-vectorization.** Reset the indexer (clears its high-water-mark so it reprocesses the existing documents that were committed with null vectors), then trigger a run:

```pwsh
Invoke-RestMethod -Method Post `
  -Uri "https://$SEARCH.search.windows.net/indexers/<indexer-name>/reset?api-version=2024-07-01" `
  -Headers @{ Authorization = "Bearer $TOKEN" }
Invoke-RestMethod -Method Post `
  -Uri "https://$SEARCH.search.windows.net/indexers/<indexer-name>/run?api-version=2024-07-01" `
  -Headers @{ Authorization = "Bearer $TOKEN" }
```

Wait 60–90 seconds (longer for large indexes) and re-check `vectorIndexSize` — it should now be > 0. Copilot Studio queries will start returning results immediately.

> **For role grants:** allow up to 15 minutes for propagation before re-running. If the indexer still produces null vectors after the wait, reset + run again — the search service caches its MI bearer token for a few minutes.

**If you provisioned via Bicep:** the current `infra/modules/rbac.bicep` and `scripts/post_deploy_search.py` together create both the right role and the skillset. Older deployments (before this audit fix) are missing the skillset — update the repo and re-run `python scripts/post_deploy_search.py` to add it; no Bicep redeploy needed.

**Also check (less common):** the vectorizer / skill definition's `authIdentity` is set correctly. `null` = system-assigned managed identity. If you used a user-assigned MI, you must set the identity ID explicitly.

### 4.2 Indexer cannot read Blob

**Symptom.** Indexer status: "The remote server returned an error: (403) Forbidden" while reading the data source.

**Cause.** AI Search MI lacks **Storage Blob Data Reader** on the storage account (or chunks container).

**Fix.**

```pwsh
$ST_RES_ID = az storage account show --name <st> -g <rg> --query id -o tsv

az role assignment create `
  --assignee-object-id $SEARCH_OBJID --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Reader" `
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

```pwsh
# Check tier
az search service show --name <srch> -g <rg> --query "sku.name"
# Expected: "standard" or higher

# Check semantic ranker queries-used in the portal (Semantic ranker blade)
```

### 4.5 Indexer schedule not firing

**Symptom.** Indexer has a schedule but no runs are happening.

**Cause.** Indexer is **disabled**, or scheduling is set on a paused service.

**Fix.**

```http
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

**Cause.** Copilot Studio routes queries through topics. If a topic matches before generative answers fires, the topic takes precedence.

**Fix.** Review the topic list, remove or narrow the trigger phrases of topics that should not intercept knowledge questions. As a stopgap: configure **Generative AI** as the primary handler and topics as escalations.

### 5.5 Cannot publish to Teams

**Cause.** Power Platform admin has not approved the channel deployment for this environment.

**Fix.** Submit the channel-publishing approval request and wait for admin approval. There is no self-service workaround.

### 5.6 Cannot publish to M365 Copilot

**Cause.** Tenant M365 admin has not enabled third-party agents in M365 Copilot.

**Fix.** Same as above — admin must enable in M365 admin center.

### 5.7 Knowledge source save fails with "key not valid"

**Symptom.** Adding AI Search as a Copilot Studio knowledge source fails when you paste an admin/query key.

**Cause.** This pattern disables local auth on AI Search (`disableLocalAuth=true`). The Keys blade still shows admin keys for backwards compatibility but the service rejects them at the data plane.

**Fix.** In the knowledge source dialog, change **Authentication** to **Microsoft Entra ID**:

- For a small / demo audience: the connecting user's identity is used; grant each user **Search Index Data Reader** on the search service.
- For broad rollout: configure a Copilot Studio connection that uses a service principal with **Search Index Data Reader** — the agent then resolves the SP identity for every user.

See [03c-copilot-studio-setup.md § C2.1](./03c-copilot-studio-setup.md#c21-add-the-knowledge-source) for the full configuration.

### 5.8 Agent works for me but fails for other users (or: "I had to add Search Index Data Reader to my own account")

**Symptom.** As the agent builder you can chat with the agent and get grounded answers, but other users (testers, end users, or even the same builder account signed into Teams instead of the Copilot Studio test pane) get **"I don't have any information"** or empty results. You may also notice that the very first query you ran failed until you granted **Search Index Data Reader** on the AI Search service to your **own user**.

**Cause.** This is **by design**, not a missed configuration. Copilot Studio's AI Search knowledge source authenticates through a Power Platform **data connection**, not through an Azure managed identity. With local auth disabled on the search service (this pattern's default), the connection can only use one of two Entra auth types — and the default the UI nudges you toward is **Microsoft Entra ID Integrated**, which flows the **calling end-user's** token to AI Search:

| Connection auth type | Identity that hits AI Search | RBAC requirement |
|---|---|---|
| **Microsoft Entra ID Integrated** | The calling **end user** (different per chat session) | **Every user** of the agent needs `Search Index Data Reader` on the search service |
| **Service principal (Microsoft Entra ID application)** | A single SP stored in the connection | Only the **SP** needs `Search Index Data Reader`; end users need no direct search RBAC |
| ~~Access Key~~ | n/a | Disabled in this pattern (`disableLocalAuth=true`) |

There is no "agent managed identity" option for the AI Search knowledge source today — managed identities only cover the Azure-side hops in this pattern (Foundry → Search, Search → Storage / embeddings, indexer auth — see [`infra/modules/search.bicep`](../infra/modules/search.bicep) and [`infra/modules/rbac.bicep`](../infra/modules/rbac.bicep)). Copilot Studio runs in Power Platform and has no Azure managed identity surface for this binding.

**Fix — pick the option that matches your audience:**

- **Demo / pilot with a known, small set of users.** Keep **Microsoft Entra ID Integrated**. Grant **Search Index Data Reader** on the AI Search service to:
  - an Entra **security group**, and add every tester / end user to that group (preferred — avoids drift), **or**
  - each individual user account.

  Role propagation can take up to 15 minutes. Until the role lands, the user sees the same "no information" / empty-results behavior.

- **Broad / production rollout.** Switch the connection to **Service principal (Microsoft Entra ID application)** — see [03c — Phase C0.3](./03c-copilot-studio-setup.md#c03-ai-search-access-pattern) and [03c — Phase C2.1](./03c-copilot-studio-setup.md#c21-add-the-knowledge-source):
  1. Create (or reuse) an Entra app registration + client secret.
  2. Grant the SP **Search Index Data Reader** on the AI Search service — **once**.
  3. In Copilot Studio, edit the AI Search knowledge source → **Edit connection** → recreate with **Service principal**, pasting the SP's tenant ID, client ID, and client secret.
  4. Remove any per-user `Search Index Data Reader` assignments you added during demo — end users no longer need them.

  The agent's access surface is then governed by **who you share the agent with** in Teams / M365 Copilot, not by per-user search RBAC. This is the recommended pattern for anything beyond a demo audience.

**Is this a way to restrict who can use the agent?** Yes — `Microsoft Entra ID Integrated` is the *strongest* of the available options for a small audience because only users with explicit search-service RBAC can retrieve, even via the agent. It is intentional, not a missing config.

**Reference.** [Add Azure AI Search as a knowledge source — Microsoft Copilot Studio docs](https://learn.microsoft.com/microsoft-copilot-studio/knowledge-azure-ai-search) (see the **Authentication** section for the full matrix of supported connection types and what each one means for end-user RBAC).

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

```http
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

If the issue is blocking a demo or production deployment, open a support case through your Azure support plan.

---

*Last updated: 2026-05-21*

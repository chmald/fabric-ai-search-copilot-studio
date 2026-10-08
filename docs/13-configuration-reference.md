[README](../README.md) › [docs index](./00-reproduce-this-demo.md) › 13 Configuration reference

# 13 — Configuration reference

<p>
<img src="./assets/icons/azure-devops.svg" width="40" alt="Azure Developer CLI / pipelines"/>&nbsp;
<img src="./assets/icons/gear.svg" width="40" alt="Configuration"/>&nbsp;
<img src="./assets/icons/file.svg" width="40" alt="demo-ids.local.json"/>&nbsp;
<img src="./assets/icons/powershell.svg" width="40" alt="PowerShell scripts"/>&nbsp;
<img src="./assets/icons/ai-search.svg" width="40" alt="Azure AI Search"/>&nbsp;
<img src="./assets/icons/foundry-models.svg" width="40" alt="Foundry Models"/>&nbsp;
<img src="./assets/icons/key-vault.svg" width="40" alt="Key Vault"/>
</p>

![Version](./assets/badges/version.svg) ![azd up](./assets/badges/azd-up.svg) ![Static only](./assets/badges/static-only.svg)

Every value you can set in this pattern, on one page: where it is set, its default, what it changes and who reads it. Use it to change a model, region, capacity, SKU, name or behaviour without reading Bicep, PowerShell or Python. It is written for whoever deploys or retargets the pattern (platform engineer, developer, or the team that will operate it) and can be forwarded on its own.

## At a glance

| | Where configuration lives | Set with | Read by | Committed? |
|---|---|---|---|---|
| <img src="./assets/icons/azure-devops.svg" width="24" alt=""/> | **azd environment** (`.azure/<env>/.env`) | `azd env set NAME value` | `infra/azd.parameters.json` → `infra/azd.bicep` → `infra/main.bicep`; the hooks | No — `.azure/` is gitignored |
| <img src="./assets/icons/file.svg" width="24" alt=""/> | **Bicep parameter file** (`infra/main.parameters.local.json`) | Edit a copy of `infra/main.parameters.json` | `infra/deploy.ps1` / `az deployment sub create` | No — `*.local.json` is gitignored |
| <img src="./assets/icons/powershell.svg" width="24" alt=""/> | **Script parameters** | `pwsh ./infra/deploy.ps1 -Name value` | The script for one run | n/a |
| <img src="./assets/icons/gear.svg" width="24" alt=""/> | **`demo-ids.local.json`** (flat Azure keys + `corpus` block + manual sections) | Written by `deploy.ps1` / the postprovision hook; `corpus` edited by hand | `scripts/post_deploy_search.py`; operators copying values into Fabric / Copilot Studio / Foundry | No — gitignored; `demo-ids.template.json` is the committed schema |
| <img src="./assets/icons/container-apps.svg" width="24" alt=""/> | **Runtime environment variables** | Container App settings (set by `scripts/deploy-webapp.ps1`) or your shell | `webapp/app/main.py`; tooling such as `DRAWIO_EXE` | No |

> [!IMPORTANT]
> **Rule of thumb.** Deployment settings are azd environment variables (or Bicep parameters on the script path); script and corpus settings are keys in `demo-ids.local.json`; **secrets are never either**. The only secret in the pattern — the DI-caller service-principal secret — lives in Key Vault (`di-sp-secret`, [06 § F2.2](./06-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook)). Everything else authenticates with managed identity or an Entra token.

## Overview — how a value flows

[![Configuration flow: azd environment and Bicep parameter files feed infra/main.bicep; its deploymentSummary output is written to demo-ids.local.json by the postprovision hook or deploy.ps1; post_deploy_search.py and the manual Fabric and agent steps read that file; runtime environment variables configure the optional web app](./assets/configuration-flow.png)](./assets/configuration-flow.png)

<sub>Editable source: [`assets/configuration-flow.drawio`](./assets/configuration-flow.drawio) - regenerate with `python scripts/export_diagrams.py docs/assets`.</sub>

**Precedence.**

| Setting kind | Highest wins → lowest |
|---|---|
| Bicep parameter (azd path) | `azd env set` value → the `${NAME=default}` default in `infra/azd.parameters.json` → the `param` default in `infra/azd.bicep` |
| Bicep parameter (script path) | `-RestoreFoundry` switch (adds `restoreFoundryFromSoftDelete=true`) → `infra/main.parameters.local.json` → the `param` default in `infra/main.bicep` |
| AI Search script setting | `corpus.<key>` in `demo-ids.local.json` → the flat top-level key of the same name (written from Bicep) → the code default in `scripts/post_deploy_search.py` |
| Web app | Container App environment variable → code default in `webapp/app/main.py` |

> [!NOTE]
> azd is an additional entry point over the **same** template. `infra/azd.bicep` passes every `infra/main.bicep` parameter through, so the azd path, the `deploy.ps1` path and the manual path ([03b](./03b-manual-deployment.md)) produce the same resources. `tests/test_configuration.py` fails if a parameter, output, hook variable, script flag or ids key is missing from this page.

---

## 1 — azd environment variables

Set with `azd env set NAME value` before `azd provision` / `azd up`. Every value in `infra/azd.parameters.json` is a quoted `${NAME=default}` substitution, so booleans and integers are written as strings (`"true"`, `"10"`) and ARM converts them.

### 1.1 Target and identity

| | Variable | Default | Effect |
|---|---|---|---|
| <img src="./assets/icons/subscription.svg" width="20" alt=""/> | `AZURE_ENV_NAME` | prompted by `azd env new` | azd environment name. Lowercase letters, digits and hyphens, ≤ 20 characters (checked by `preprovision`). Becomes the `azd-env-name` tag and the deployment name `main-<env>`; resource names come from `WORKLOAD_NAME` / `WORKLOAD_ENV` / region. |
| <img src="./assets/icons/entra-id.svg" width="20" alt=""/> | `AZURE_TENANT_ID` | none — **set it** | Tenant the deployment must target. `preprovision` stops unless `az account show` returns this tenant. |
| <img src="./assets/icons/subscription.svg" width="20" alt=""/> | `AZURE_SUBSCRIPTION_ID` | prompted by azd | Subscription the deployment must target (same guard). |
| <img src="./assets/icons/resource-group.svg" width="20" alt=""/> | `AZURE_LOCATION` | `eastus2` | Region for every resource. Tier-1 list: [02 § 11](./02-prerequisites.md). Maps to `location`. |
| <img src="./assets/icons/resource-group.svg" width="20" alt=""/> | `AZURE_RESOURCE_GROUP` | empty → `rg-<workload>-<env>-<region>` | Existing or desired resource group name. Maps to `resourceGroupName`. Overwritten by the `AZURE_RESOURCE_GROUP` output after provisioning. |
| <img src="./assets/icons/users.svg" width="20" alt=""/> | `AZURE_PRINCIPAL_ID` | set by azd (signed-in identity) | Granted Search Service Contributor + Search Index Data Contributor + Key Vault Secrets Officer. Maps to `deployerPrincipalId`. |
| <img src="./assets/icons/users.svg" width="20" alt=""/> | `AZURE_PRINCIPAL_TYPE` | `User` | `User` or `ServicePrincipal` (CI). Maps to `deployerPrincipalType`. |

### 1.2 Platform and naming

| | Variable | Default | Effect |
|---|---|---|---|
| <img src="./assets/icons/gear.svg" width="20" alt=""/> | `WORKLOAD_NAME` | `rag` | 2–8 lowercase letters/digits; part of every resource name. `preprovision` checks the storage account name stays ≤ 24 characters. Maps to `workloadName`. |
| <img src="./assets/icons/gear.svg" width="20" alt=""/> | `WORKLOAD_ENV` | `dev` | `dev`, `test` or `prod`; part of every resource name. Maps to `env`. |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `SEARCH_SKU` | `standard` | `basic`, `standard`, `standard2`, `standard3`. Basic is a valid cost-down choice — semantic ranker, integrated vectorization and managed identity all work on it. Maps to `searchSku`. |
| <img src="./assets/icons/container-apps.svg" width="20" alt=""/> | `DEPLOY_WEB_APP` | `false` | `true` adds the optional web-app platform (Container Apps environment, ACR, Log Analytics, user-assigned identity) for [12](./12-foundry-agent-webapp.md). Maps to `deployWebApp`. |
| <img src="./assets/icons/foundry.svg" width="20" alt=""/> | `RESTORE_FOUNDRY_FROM_SOFT_DELETE` | `false` — **managed by `preprovision`** | Restores a soft-deleted Foundry account of the same name in place (keeps its managed-identity principal and grants). `preprovision` sets it to match reality, because `true` without a deleted account fails (`CanNotRestoreANonExistingResource`) and `false` with one fails (`FlagMustBeSetForRestore`). Maps to `restoreFoundryFromSoftDelete`. |

### 1.3 Models and capacity

| | Variable | Default | Effect |
|---|---|---|---|
| <img src="./assets/icons/foundry-models.svg" width="20" alt=""/> | `EMBEDDING_MODEL_NAME` | `text-embedding-3-large` | Embedding model for index-time and query-time vectors. `text-embedding-3-small` halves the vector width (1536) and cost. Maps to `embeddingModelName`. |
| <img src="./assets/icons/foundry-models.svg" width="20" alt=""/> | `EMBEDDING_MODEL_VERSION` | empty (service default) | Pin a version for reproducibility. Maps to `embeddingModelVersion`. |
| <img src="./assets/icons/foundry-models.svg" width="20" alt=""/> | `EMBEDDING_MODEL_SKU` | `Standard` | `Standard`, `GlobalStandard` or `DataZoneStandard` — match where your quota is. Maps to `embeddingModelSku`. |
| <img src="./assets/icons/foundry-models.svg" width="20" alt=""/> | `EMBEDDING_MODEL_TPM` | `10` | Capacity in thousands of tokens per minute. 10 is enough for a demo corpus; raise it for bulk indexing. Maps to `embeddingModelTpm`. |
| <img src="./assets/icons/azure-openai.svg" width="20" alt=""/> | `CHAT_MODEL_NAME` | empty (no chat deployment) | ![Opt-in](./assets/badges/opt-in.svg) **Opt-in.** The default Copilot Studio path answers with its host model. Set a current GA chat model (for example `gpt-5.5`, or `gpt-5.4-mini` for cost-down) for the Foundry agent path ([08](./08-foundry-agent-setup.md)), custom code or a bring-your-own-model setup. Maps to `chatModelName`. |
| <img src="./assets/icons/azure-openai.svg" width="20" alt=""/> | `CHAT_MODEL_VERSION` | empty (service default) | Pin a version, e.g. `2026-04-24` for `gpt-5.5`. Maps to `chatModelVersion`. |
| <img src="./assets/icons/azure-openai.svg" width="20" alt=""/> | `CHAT_MODEL_SKU` | `GlobalStandard` | Current GA chat models deploy as `GlobalStandard`. Maps to `chatModelSku`. |
| <img src="./assets/icons/azure-openai.svg" width="20" alt=""/> | `CHAT_MODEL_TPM` | `10` | Capacity in thousands of tokens per minute. Maps to `chatModelTpm`. |

> [!WARNING]
> **Model currency.** Check the [model retirement schedule](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirement-schedule) before pinning a chat model. As of 2026-10-07 `gpt-4o` (2024-05-13) retires on 2026-12-09 and the other `gpt-4o` / `gpt-4o-mini` versions on 2027-04-14, so this pattern no longer suggests them. `text-embedding-3-large` / `-small` (version 1) are GA until 2028-02-09.

### 1.4 Hook behaviour

| | Variable | Default | Effect |
|---|---|---|---|
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `CONFIGURE_SEARCH` | `true` | `postprovision` runs `scripts/post_deploy_search.py` (index, data source, skillset, indexer). Set `false` to do it later by hand. |
| <img src="./assets/icons/key-vault.svg" width="20" alt=""/> | `PURGE_SOFT_DELETED` | `false` | `true` makes `preprovision` **purge** a soft-deleted Foundry account / Key Vault with the target name instead of restoring / recovering it. Destructive and irreversible. |

### 1.5 Outputs written back

`infra/azd.bicep` re-exports the `deploymentSummary` of `infra/main.bicep` as UPPER_SNAKE_CASE outputs. azd stores them in `.azure/<env>/.env`; `postprovision` writes them to `demo-ids.local.json`.

<details><summary><b>Show every output and the demo-ids key it becomes</b></summary>

| Output | `demo-ids.local.json` key |
|---|---|
| `AZURE_RESOURCE_GROUP` | `resourceGroup` |
| `STORAGE_ACCOUNT_NAME` | `storageAccount` |
| `BLOB_ENDPOINT` | `blobEndpoint` |
| `RAW_CONTAINER` | `rawContainer` |
| `CHUNKS_CONTAINER` | `chunksContainer` |
| `KEY_VAULT_NAME` | `keyVault` |
| `KEY_VAULT_URI` | `keyVaultUri` |
| `FOUNDRY_RESOURCE_NAME` | `foundryResource` |
| `FOUNDRY_OPENAI_ENDPOINT` | `foundryOpenAIEndpoint` |
| `DOCUMENT_INTELLIGENCE_ENDPOINT` | `documentIntelligenceEndpoint` |
| `EMBEDDING_DEPLOYMENT` | `embeddingDeployment` |
| `CHAT_DEPLOYMENT` | `chatDeployment` |
| `CHAT_DEPLOYED` | `chatDeployed` |
| `SEARCH_SERVICE_NAME` | `searchService` |
| `SEARCH_ENDPOINT` | `searchEndpoint` |
| `SEARCH_PRINCIPAL_ID` | `searchPrincipalId` |
| `SEARCH_INDEX_NAME` | `searchIndexName` |
| `SEARCH_DATA_SOURCE_NAME` | `searchDataSourceName` |
| `SEARCH_INDEXER_NAME` | `searchIndexerName` |
| `DEPLOYER_HAS_SEARCH_ROLES` | `deployerHasSearchRoles` |
| `WEBAPP_DEPLOYED` | `webAppDeployed` |
| `WEBAPP_ACR_NAME` | `webAppAcr` |
| `WEBAPP_ACR_LOGIN_SERVER` | `webAppAcrLoginServer` |
| `WEBAPP_ENVIRONMENT_NAME` | `webAppEnvironment` |
| `WEBAPP_IDENTITY_NAME` | `webAppIdentityName` |
| `WEBAPP_IDENTITY_CLIENT_ID` | `webAppIdentityClientId` |
| `WEBAPP_IDENTITY_RESOURCE_ID` | `webAppIdentityResourceId` |

`subscriptionId`, `tenantId`, `region`, `environment`, `workload`, `embeddingModel` and `chatModel` come from the azd inputs (`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_LOCATION`, `WORKLOAD_ENV`, `WORKLOAD_NAME`, `EMBEDDING_MODEL_NAME`, `CHAT_MODEL_NAME`); `authMode` and `localAuthDisabled` are constants.

</details>

---

## 2 — Script path and Bicep parameters

### 2.1 `infra/main.bicep` parameters ↔ azd variables

| | Bicep parameter | azd variable | Default |
|---|---|---|---|
| <img src="./assets/icons/resource-group.svg" width="20" alt=""/> | `location` | `AZURE_LOCATION` | (required) |
| <img src="./assets/icons/resource-group.svg" width="20" alt=""/> | `resourceGroupName` | `AZURE_RESOURCE_GROUP` | empty → convention |
| <img src="./assets/icons/gear.svg" width="20" alt=""/> | `workloadName` | `WORKLOAD_NAME` | `rag` |
| <img src="./assets/icons/gear.svg" width="20" alt=""/> | `env` | `WORKLOAD_ENV` | `dev` |
| <img src="./assets/icons/foundry-models.svg" width="20" alt=""/> | `embeddingModelName` / `embeddingModelVersion` / `embeddingModelSku` / `embeddingModelTpm` | `EMBEDDING_MODEL_*` | `text-embedding-3-large` / empty / `Standard` / `10` |
| <img src="./assets/icons/azure-openai.svg" width="20" alt=""/> | `chatModelName` / `chatModelVersion` / `chatModelSku` / `chatModelTpm` | `CHAT_MODEL_*` | empty / empty / `GlobalStandard` / `10` |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `searchSku` | `SEARCH_SKU` | `standard` |
| <img src="./assets/icons/users.svg" width="20" alt=""/> | `deployerPrincipalId` / `deployerPrincipalType` | `AZURE_PRINCIPAL_ID` / `AZURE_PRINCIPAL_TYPE` | empty / `User` |
| <img src="./assets/icons/container-apps.svg" width="20" alt=""/> | `deployWebApp` | `DEPLOY_WEB_APP` | `false` |
| <img src="./assets/icons/foundry.svg" width="20" alt=""/> | `restoreFoundryFromSoftDelete` | `RESTORE_FOUNDRY_FROM_SOFT_DELETE` | `false` |
| <img src="./assets/icons/gear.svg" width="20" alt=""/> | `tags` | (fixed in `infra/azd.bicep`, plus `azd-env-name`) | `workload`, `pattern` |

### 2.2 `infra/deploy.ps1`

| | Parameter | Default | azd equivalent |
|---|---|---|---|
| <img src="./assets/icons/file.svg" width="20" alt=""/> | `-ParameterFile` | `infra/main.parameters.local.json` | the azd environment |
| <img src="./assets/icons/code.svg" width="20" alt=""/> | `-DeploymentName` | `rag-kb-bicep-<timestamp>` | `main-<AZURE_ENV_NAME>` |
| <img src="./assets/icons/code.svg" width="20" alt=""/> | `-WhatIf` | off | `azd provision --preview` ![azd up](./assets/badges/azd-up.svg) |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `-SkipPostDeploy` | off | `CONFIGURE_SEARCH=false` |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `-Verify` | off | `python scripts/post_deploy_search.py --ids demo-ids.local.json --verify` |
| <img src="./assets/icons/foundry.svg" width="20" alt=""/> | `-RestoreFoundry` | off | automatic in `preprovision` |
| <img src="./assets/icons/entra-id.svg" width="20" alt=""/> | `-TenantId` / `-SubscriptionId` | empty (guard off) | `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` (guard always on) |

### 2.3 Other scripts

| | Script | Options |
|---|---|---|
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `scripts/post_deploy_search.py` | `--ids` (default `demo-ids.local.json`), `--verify` (smoke tests only), `--run-indexer` (trigger a run after configuring) |
| <img src="./assets/icons/container-apps.svg" width="20" alt=""/> | `scripts/deploy-webapp.ps1` | `-IdsFile`, `-AppName`, `-AgentTokenScope` (default `https://ai.azure.com/.default`), `-EnableObo`, `-WhatIf` — see [12](./12-foundry-agent-webapp.md) |
| <img src="./assets/icons/media-file.svg" width="20" alt=""/> | `scripts/export_diagrams.py` | `paths…`, `--scale` (default 2), `--border` (default 20), `--check` (fail on a missing or stale PNG) |
| <img src="./assets/icons/file.svg" width="20" alt=""/> | `scripts/lint_doc_visuals.py` | `--root`, `--strict`, `--no-diagram`, `--quiet` |

---

## 3 — `demo-ids.local.json`

The committed schema is `demo-ids.template.json`. The live file is gitignored.

### 3.1 Written for you (flat keys)

Overwritten on every successful deploy from the `deploymentSummary` output: `subscriptionId`, `tenantId`, `resourceGroup`, `region`, `environment`, `workload`, `storageAccount`, `blobEndpoint`, `rawContainer`, `chunksContainer`, `keyVault`, `keyVaultUri`, `foundryResource`, `foundryOpenAIEndpoint`, `documentIntelligenceEndpoint`, `embeddingDeployment`, `embeddingModel`, `chatDeployment`, `chatModel`, `chatDeployed`, `searchService`, `searchEndpoint`, `searchPrincipalId`, `searchIndexName`, `searchDataSourceName`, `searchIndexerName`, `authMode`, `localAuthDisabled`, `deployerHasSearchRoles`, `webAppDeployed`, `webAppAcr`, `webAppAcrLoginServer`, `webAppEnvironment`, `webAppIdentityName`, `webAppIdentityClientId`, `webAppIdentityResourceId`.

### 3.2 The `corpus` block — the only domain-specific surface

Seeded from the template on first write and never overwritten. Retargeting the pattern at a new document domain means editing this block — no code changes ([01 § Adapting this pattern](./01-architecture.md)).

| | Key | Default | Consumed by |
|---|---|---|---|
| <img src="./assets/icons/file.svg" width="20" alt=""/> | `displayName` | `Document knowledge base` | Human label for the corpus (agent and knowledge-source names) |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `searchIndexName` | `idx-rag-documents` | `post_deploy_search.py` (overrides the flat key); Copilot Studio / Foundry knowledge binding |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `searchSkillsetName` | `skill-rag-embeddings` | `post_deploy_search.py` |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `contentAnalyzer` | `en.microsoft` | `post_deploy_search.py` — language analyzer on the `content` field (e.g. `de.microsoft`, `fr.lucene`) |
| <img src="./assets/icons/foundry-models.svg" width="20" alt=""/> | `embeddingDimensions` | `null` (derived: 3072 for `-3-large`, 1536 for `-3-small`) | `post_deploy_search.py` — set it when you change the embedding model or request reduced dimensions |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `indexerSchedule` | `PT5M` | `post_deploy_search.py` — ISO-8601 interval for the indexer |
| <img src="./assets/icons/ai-search.svg" width="20" alt=""/> | `searchApiVersion` | `2024-07-01` | `post_deploy_search.py` — data-plane REST version. Latest ![GA](./assets/badges/ga.svg) version is `2026-04-01` (no breaking changes for the features used here) |
| <img src="./assets/icons/document-intelligence.svg" width="20" alt=""/> | `acceptedFileTypes` | `.pdf .docx .jpg .jpeg .png .tiff .bmp` | Fabric pipeline file filter ([06](./06-fabric-setup.md)) |
| <img src="./assets/icons/dev-console.svg" width="20" alt=""/> | `chunkSizeTokens` / `chunkOverlapTokens` | `1000` / `200` | `nb_ocr_chunk_upload` notebook constants ([06 § F7.2](./06-fabric-setup.md#f72-nb_ocr_chunk_upload)) |
| <img src="./assets/icons/foundry-agent-service.svg" width="20" alt=""/> | `agentName` | `agent-rag-kb` | Copilot Studio ([07](./07-copilot-studio-setup.md)) / Foundry agent ([08](./08-foundry-agent-setup.md)) name |
| <img src="./assets/icons/foundry-agent-service.svg" width="20" alt=""/> | `knowledgeSourceName` / `knowledgeSourceDescription` | neutral defaults | Knowledge-source / tool name and description. The agent picks the tool **by its description**, so this is the highest-impact per-domain setting |

### 3.3 Maintained by hand

| | Section | Filled during | Notes |
|---|---|---|---|
| <img src="./assets/icons/data-factory.svg" width="20" alt=""/> | `fabric` | [06](./06-fabric-setup.md) | Capacity, workspace, Lakehouse, SQL endpoint and pipeline IDs |
| <img src="./assets/icons/app-registrations.svg" width="20" alt=""/> | `sp-rag-di-caller` | [06 § F2.2](./06-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook) | The secret's canonical home is Key Vault (`di-sp-secret`); remove the local copy once retrieval is validated |
| <img src="./assets/icons/users.svg" width="20" alt=""/> | `copilotStudio` | [07](./07-copilot-studio-setup.md) | Power Platform environment region, agent name, knowledge source, channels |

The script also accepts an optional flat `searchSkillsetName` key (older files); `corpus.searchSkillsetName` wins.

---

## 4 — Runtime environment variables

| | Variable | Default | Read by |
|---|---|---|---|
| <img src="./assets/icons/foundry-project.svg" width="20" alt=""/> | `FOUNDRY_PROJECT_ENDPOINT` | none | `webapp/app/main.py` — `https://<resource>.services.ai.azure.com/api/projects/<project>` |
| <img src="./assets/icons/foundry-agent-service.svg" width="20" alt=""/> | `AGENT_ID` | none | `webapp/app/main.py` — the agent the app talks to |
| <img src="./assets/icons/managed-identity.svg" width="20" alt=""/> | `AZURE_CLIENT_ID` | none | `webapp/app/main.py` — the app's user-assigned managed identity |
| <img src="./assets/icons/entra-id.svg" width="20" alt=""/> | `ENABLE_OBO` | `false` | `webapp/app/main.py` — `true` calls the agent as the signed-in user |
| <img src="./assets/icons/app-registrations.svg" width="20" alt=""/> | `OBO_CLIENT_ID` | none | `webapp/app/main.py` (OBO only) — app registration for the token exchange |
| <img src="./assets/icons/entra-id.svg" width="20" alt=""/> | `AZURE_TENANT_ID` | none | `webapp/app/main.py` (OBO only) — authority tenant |
| <img src="./assets/icons/keys.svg" width="20" alt=""/> | `AGENT_TOKEN_SCOPE` | `https://ai.azure.com/.default` | `webapp/app/main.py` — Foundry data-plane audience |
| <img src="./assets/icons/monitor.svg" width="20" alt=""/> | `LOG_LEVEL` | `INFO` | `webapp/app/main.py` |
| <img src="./assets/icons/media-file.svg" width="20" alt=""/> | `DRAWIO_EXE` | auto-detected | `scripts/export_diagrams.py` — path to the draw.io desktop executable |

---

## 5 — Recipes

| Goal | Do this |
|---|---|
| **Cheapest demo stand-up** | `azd env set SEARCH_SKU basic` · `azd env set EMBEDDING_MODEL_NAME text-embedding-3-small` · then `azd up` |
| **Add the Foundry agent path's chat model** | `azd env set CHAT_MODEL_NAME gpt-5.5` · `azd env set CHAT_MODEL_VERSION 2026-04-24` · `azd provision` |
| **Second environment side by side** | `azd env new kb-test` · `azd env set WORKLOAD_ENV test` · set tenant/subscription/region · `azd up` |
| **Use an existing resource group** | `azd env set AZURE_RESOURCE_GROUP <name>` (same region as `AZURE_LOCATION`) |
| **Provision now, configure AI Search later** | `azd env set CONFIGURE_SEARCH false` · later `python scripts/post_deploy_search.py --ids demo-ids.local.json` |
| **Retarget to another document domain** | Edit `corpus` in `demo-ids.local.json` (index/skillset names, analyzer, chunking, agent + knowledge-source description) · re-run `post_deploy_search.py` |
| **Swap the embedding model** | `azd env set EMBEDDING_MODEL_NAME <model>` · set `corpus.embeddingDimensions` if the width isn't 3072/1536 · re-provision · delete + recreate the index (vector width can't change in place) |
| **Same-name redeploy after a teardown** | Nothing — `preprovision` restores the soft-deleted Foundry account and recovers the Key Vault. To start clean instead: `azd env set PURGE_SOFT_DELETED true` |
| **Script path with a tenant guard** | `pwsh ./infra/deploy.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -Verify` |

> [!CAUTION]
> `azd down --purge` and `PURGE_SOFT_DELETED=true` permanently delete the Foundry account and Key Vault, including anything granted to the Foundry managed identity by hand (the DI-caller service principal's role in [06 § F2.2](./06-fabric-setup.md#f22-create-a-di-caller-service-principal-for-msal-from-the-notebook)). Fabric and Copilot Studio artifacts are not touched — delete them in their own portals.

---

Next: [README](../README.md) →

*Last updated: 2026-10-07*

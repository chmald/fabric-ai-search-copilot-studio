// =====================================================================================
// main.bicep — RAG Knowledge-Base Pattern
// =====================================================================================
//
// Provisions the Azure platform layer:
//   * Resource group
//   * Key Vault (RBAC-mode)
//   * Storage account + raw/ and chunks/ containers
//   * Microsoft Foundry resource (kind=AIServices) — multi-service Cognitive Services
//     account that provides:
//        - Azure OpenAI embedding deployment (text-embedding-3-large) — required
//        - Azure OpenAI chat deployment (gpt-4o) — OPTIONAL (only provisioned when
//          chatModelName param is non-empty; the locked design — Copilot Studio +
//          AI Search hybrid index + integrated vectorizer — does NOT consume a chat
//          completion model. Copilot Studio uses its own host model.)
//        - Document Intelligence (prebuilt-read OCR, same endpoint, same MI)
//     A separate Microsoft.CognitiveServices/accounts of kind=FormRecognizer is NOT
//     provisioned — Foundry's AIServices kind exposes the DI API surface natively
//     via the same `*.cognitiveservices.azure.com` endpoint.
//   * Azure AI Search Standard S1 (semantic ranker enabled, system-assigned MI)
//   * RBAC role assignments:
//        - AI Search MI -> Cognitive Services OpenAI User on Foundry (integrated vectorizer)
//        - AI Search MI -> Storage Blob Data Reader on Storage (indexer pulls chunks/)
//        - Foundry MI -> Storage Blob Data Reader on Storage
//          (DI fetches raw/<file> via urlSource using Foundry's own MI — required
//          because shared-key access on Storage is disabled)
//        - (Optional, when deployerPrincipalId is set) deployer ->
//          Search Service Contributor + Search Index Data Contributor on AI Search
//          so the post-deploy script can authenticate with a bearer token instead
//          of admin keys (which are disabled).
//
// Auth posture:
//   * disableLocalAuth=true on Foundry, AI Search
//   * allowSharedKeyAccess=false on Storage
//   All clients (vectorizer, indexer, Fabric pipeline, app code, scripts) authenticate
//   with Entra ID bearer tokens via managed identity or service principal.
//
// Does NOT provision (handled by scripts/post_deploy_search.py):
//   * AI Search index (vector + hybrid + semantic configuration)
//   * AI Search data source (managed-identity connection to Blob)
//   * AI Search indexer (with integrated AOAI vectorizer)
//
// Does NOT provision (manual portal steps — see docs/00-reproduce-this-demo.md Parts C, D):
//   * Fabric workspace + Lakehouse + Data Pipeline
//   * Copilot Studio agent
//
// Usage:
//   az deployment sub create \
//     --location <region> \
//     --template-file infra/main.bicep \
//     --parameters infra/main.parameters.local.json
// =====================================================================================

targetScope = 'subscription'

// -------------------------- Parameters ----------------------------------------

@description('Azure region for all resources. Choose from Tier-1 list in docs/02-prerequisites.md § 11 (default recommendations: eastus2 / swedencentral / australiaeast / japaneast).')
param location string

@description('Workload name used in resource naming. Kept short to fit storage account 24-char limit.')
@minLength(2)
@maxLength(8)
param workloadName string = 'rag'

@description('Environment label (dev | test | prod). Used in resource naming and tagging.')
@allowed([
  'dev'
  'test'
  'prod'
])
param env string = 'dev'

@description('OpenAI embedding model. Recommended: text-embedding-3-large. Acceptable cost-down: text-embedding-3-small.')
param embeddingModelName string = 'text-embedding-3-large'

@description('OpenAI embedding model version. Leave blank to let Azure pick latest.')
param embeddingModelVersion string = ''

@description('OpenAI embedding deployment TPM capacity in units of 1000 (e.g. 10 = 10K TPM).')
@minValue(1)
@maxValue(2000)
param embeddingModelTpm int = 10

@description('OpenAI chat model. Default is EMPTY (no chat deployment is provisioned) because the locked design — Copilot Studio + AI Search hybrid index + integrated vectorizer — does NOT consume a chat completion model. Copilot Studio uses its own host model for generative answers. Set this to `gpt-4o` (or `gpt-4o-mini` for cost-down) only when an engagement explicitly needs a chat endpoint: custom app code calling completions, Foundry agent runtime, or a Copilot Studio bring-your-own-model configuration.')
param chatModelName string = ''

@description('OpenAI chat model version. Leave blank to let Azure pick latest. Ignored when chatModelName is empty.')
param chatModelVersion string = ''

@description('OpenAI chat deployment TPM capacity in units of 1000 (e.g. 10 = 10K TPM). Ignored when chatModelName is empty.')
@minValue(1)
@maxValue(2000)
param chatModelTpm int = 10

@description('Set to true ONLY when redeploying after a `FlagMustBeSetForRestore` failure (Azure soft-delete recovery). When true, the Foundry account is restored in place from soft-delete, preserving the system-assigned MI principal ID and any role assignments granted to it. CAUTION: setting this to true on a fresh deploy (no soft-deleted account to restore) fails with `CanNotRestoreANonExistingResource`. Default false. See docs/06-troubleshooting.md § 0.5.')
param restoreFoundryFromSoftDelete bool = false

@description('AI Search SKU. Standard (S1) or higher REQUIRED for semantic ranker — do not select Free or Basic.')
@allowed([
  'standard'
  'standard2'
  'standard3'
])
param searchSku string = 'standard'

@description('Optional: object ID of the identity that will run the post-deploy script (scripts/post_deploy_search.py). When provided, the deployment grants Search Service Contributor + Search Index Data Contributor on the AI Search service so the script can authenticate with a bearer token. Find your own value with: az ad signed-in-user show --query id -o tsv. Leave blank to assign these roles manually.')
param deployerPrincipalId string = ''

@description('Principal type for deployerPrincipalId. Use User for an interactive az login identity (typical for first deploy), or ServicePrincipal for a CI/CD service principal or workload identity.')
@allowed([
  'User'
  'ServicePrincipal'
])
param deployerPrincipalType string = 'User'

@description('Set to true to also provision the OPTIONAL web-app hosting platform (Container Apps environment, Log Analytics, an Azure Container Registry, and a user-assigned managed identity) for the standalone chat front end in webapp/app. The container image is built and deployed afterwards by scripts/deploy-webapp.ps1. Default false — the base pattern (Copilot Studio path) does not need it; enable it for the Foundry-agent web-app front end (docs/09).')
param deployWebApp bool = false

@description('Tags applied to all resources for cost allocation + governance.')
param tags object = {
  workload: 'rag'
  pattern: 'rag-knowledge-base-pattern'
}

// -------------------------- Naming --------------------------------------------

var locationShort = toLower(replace(replace(location, ' ', ''), '-', ''))
var nameSuffix    = '${workloadName}-${env}-${locationShort}'
var stgName       = toLower(replace('st${workloadName}${env}${locationShort}', '-', ''))

var rgName         = 'rg-${nameSuffix}'
var kvName         = take('kv-${nameSuffix}', 24)
var aifName        = 'aif-${nameSuffix}'
var searchName     = 'srch-${nameSuffix}'

// Optional web-app platform naming (only used when deployWebApp = true).
var acrName        = take(toLower(replace('acr${workloadName}${env}${locationShort}', '-', '')), 50)
var caeName        = 'cae-${nameSuffix}'
var lawName        = 'law-${nameSuffix}'
var webIdName      = 'id-${nameSuffix}-web'

var mergedTags = union(tags, {
  environment: env
  region: location
})

// -------------------------- Resource group ------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: mergedTags
}

// -------------------------- Module deployments --------------------------------

module keyVault 'modules/keyvault.bicep' = {
  scope: rg
  name: 'kv-deploy'
  params: {
    name: kvName
    location: location
    tags: mergedTags
  }
}

module storage 'modules/storage.bicep' = {
  scope: rg
  name: 'storage-deploy'
  params: {
    name: stgName
    location: location
    tags: mergedTags
    containers: [
      'raw'
      'chunks'
    ]
  }
}

module foundry 'modules/aifoundry.bicep' = {
  scope: rg
  name: 'foundry-deploy'
  params: {
    name: aifName
    location: location
    tags: mergedTags
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingModelTpm: embeddingModelTpm
    chatModelName: chatModelName
    chatModelVersion: chatModelVersion
    chatModelTpm: chatModelTpm
    restoreFromSoftDelete: restoreFoundryFromSoftDelete
  }
}

module search 'modules/search.bicep' = {
  scope: rg
  name: 'search-deploy'
  params: {
    name: searchName
    location: location
    tags: mergedTags
    sku: searchSku
  }
}

module rbac 'modules/rbac.bicep' = {
  scope: rg
  name: 'rbac-deploy'
  params: {
    searchPrincipalId: search.outputs.systemAssignedPrincipalId
    foundryPrincipalId: foundry.outputs.systemAssignedPrincipalId
    storageAccountName: storage.outputs.name
    foundryAccountName: foundry.outputs.name
    searchServiceName: search.outputs.name
    keyVaultName: keyVault.outputs.name
    deployerPrincipalId: deployerPrincipalId
    deployerPrincipalType: deployerPrincipalType
  }
}

// Optional: web-app hosting platform for the Foundry-agent chat front end (docs/09).
// The container image is built + deployed by scripts/deploy-webapp.ps1 after this run.
module webapp 'modules/containerapp.bicep' = if (deployWebApp) {
  scope: rg
  name: 'webapp-deploy'
  params: {
    acrName: acrName
    environmentName: caeName
    logAnalyticsName: lawName
    identityName: webIdName
    location: location
    tags: mergedTags
    foundryAccountName: foundry.outputs.name
  }
}

// -------------------------- Outputs -------------------------------------------

output deploymentSummary object = {
  subscriptionId: subscription().subscriptionId
  tenantId: subscription().tenantId
  resourceGroup: rgName
  region: location
  environment: env
  workload: workloadName

  // Storage
  storageAccount: storage.outputs.name
  blobEndpoint: storage.outputs.blobEndpoint
  rawContainer: 'raw'
  chunksContainer: 'chunks'

  // Key Vault
  keyVault: keyVault.outputs.name
  keyVaultUri: keyVault.outputs.uri

  // Foundry (multi-service Cognitive Services — OpenAI models + Document Intelligence)
  foundryResource: foundry.outputs.name
  foundryOpenAIEndpoint: foundry.outputs.openAIEndpoint
  // Document Intelligence (prebuilt-read OCR) is served by the SAME Foundry account
  // at its generic Cognitive Services endpoint. The Fabric pipeline's OCR notebook
  // points the azure-ai-documentintelligence SDK at this URL.
  documentIntelligenceEndpoint: foundry.outputs.cognitiveServicesEndpoint
  embeddingDeployment: foundry.outputs.embeddingDeploymentName
  embeddingModel: embeddingModelName
  chatDeployment: foundry.outputs.chatDeploymentName
  chatModel: chatModelName
  chatDeployed: !empty(chatModelName)

  // AI Search
  searchService: search.outputs.name
  searchEndpoint: search.outputs.endpoint
  searchPrincipalId: search.outputs.systemAssignedPrincipalId
  searchIndexName: 'idx-rag-documents'
  searchDataSourceName: 'ds-chunks'
  searchIndexerName: 'ixr-chunks'

  // Auth posture — surfaced so tooling can branch correctly
  authMode: 'entra-only'
  localAuthDisabled: true
  deployerHasSearchRoles: !empty(deployerPrincipalId)

  // Web app (optional — populated only when deployWebApp = true). Consumed by
  // scripts/deploy-webapp.ps1 to build + deploy webapp/app into this platform.
  webAppDeployed: deployWebApp
  webAppAcr: webapp.?outputs.acrName ?? ''
  webAppAcrLoginServer: webapp.?outputs.acrLoginServer ?? ''
  webAppEnvironment: webapp.?outputs.environmentName ?? ''
  webAppIdentityName: webapp.?outputs.identityName ?? ''
  webAppIdentityClientId: webapp.?outputs.identityClientId ?? ''
  webAppIdentityResourceId: webapp.?outputs.identityResourceId ?? ''
}

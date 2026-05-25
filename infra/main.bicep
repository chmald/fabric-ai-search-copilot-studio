// =====================================================================================
// main.bicep — RAG Knowledge-Base Pattern
// =====================================================================================
//
// Provisions the Azure platform layer:
//   * Resource group
//   * Key Vault (RBAC-mode)
//   * Storage account + raw/ and chunks/ containers
//   * Azure AI Foundry resource (kind=AIServices) — multi-service Cognitive Services
//     account that provides BOTH:
//        - Azure OpenAI deployments (text-embedding-3-large + gpt-4o)
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

@description('OpenAI chat model. Recommended: gpt-4o. Acceptable cost-down: gpt-4o-mini.')
param chatModelName string = 'gpt-4o'

@description('OpenAI chat model version. Leave blank to let Azure pick latest.')
param chatModelVersion string = ''

@description('OpenAI chat deployment TPM capacity in units of 1000 (e.g. 10 = 10K TPM).')
@minValue(1)
@maxValue(2000)
param chatModelTpm int = 10

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
    deployerPrincipalId: deployerPrincipalId
    deployerPrincipalType: deployerPrincipalType
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
}

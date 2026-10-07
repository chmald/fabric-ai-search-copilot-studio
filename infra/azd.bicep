// =====================================================================================
// azd.bicep — Azure Developer CLI entry point (`azd up` / `azd provision`)
// =====================================================================================
//
// Subscription-scoped wrapper over the SHARED infra/main.bicep. It passes every
// main.bicep parameter through (tests/test_configuration.py enforces this) and
// re-exports the deployment summary as UPPER_SNAKE_CASE outputs, which azd writes to
// .azure/<env>/.env and the postprovision hook turns into demo-ids.local.json.
//
// main.bicep creates (or reuses, via AZURE_RESOURCE_GROUP) the resource group itself,
// so this wrapper only adds the azd-env-name tag azd uses to find the resources on
// `azd down`.
// =====================================================================================

targetScope = 'subscription'

@description('azd environment name (AZURE_ENV_NAME). Lowercase alphanumeric plus hyphen, max 20 - enforced again by the preprovision hook. Used for the azd-env-name tag and the deployment name; resource names come from workloadName/env/location.')
@maxLength(20)
param environmentName string

@description('Azure region (AZURE_LOCATION). Tier-1 regions: docs/02-prerequisites.md section 11.')
param location string

@description('Optional resource group name (AZURE_RESOURCE_GROUP). Empty = rg-<workload>-<env>-<region>.')
param resourceGroupName string = ''

@description('Object ID of the identity running azd (AZURE_PRINCIPAL_ID, provided by azd). Granted the search + Key Vault roles the postprovision hook needs.')
param principalId string = ''

@description('Principal type of AZURE_PRINCIPAL_ID.')
@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string = 'User'

@description('Workload name used in resource naming (2-8 lowercase alphanumeric).')
@minLength(2)
@maxLength(8)
param workloadName string = 'rag'

@description('Environment label used in resource naming.')
@allowed([
  'dev'
  'test'
  'prod'
])
param workloadEnv string = 'dev'

param embeddingModelName string = 'text-embedding-3-large'
param embeddingModelVersion string = ''
@allowed([
  'Standard'
  'GlobalStandard'
  'DataZoneStandard'
])
param embeddingModelSku string = 'Standard'
param embeddingModelTpm int = 10

param chatModelName string = ''
param chatModelVersion string = ''
@allowed([
  'Standard'
  'GlobalStandard'
  'DataZoneStandard'
])
param chatModelSku string = 'GlobalStandard'
param chatModelTpm int = 10

@allowed([
  'basic'
  'standard'
  'standard2'
  'standard3'
])
param searchSku string = 'standard'

param deployWebApp bool = false
param restoreFoundryFromSoftDelete bool = false

@description('Tags applied to every resource. azd-env-name is added so `azd down` can find the resource group.')
param tags object = {
  workload: 'rag'
  pattern: 'rag-knowledge-base-pattern'
}

module main 'main.bicep' = {
  name: 'main-${environmentName}'
  params: {
    location: location
    workloadName: workloadName
    env: workloadEnv
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingModelSku: embeddingModelSku
    embeddingModelTpm: embeddingModelTpm
    chatModelName: chatModelName
    chatModelVersion: chatModelVersion
    chatModelSku: chatModelSku
    chatModelTpm: chatModelTpm
    restoreFoundryFromSoftDelete: restoreFoundryFromSoftDelete
    searchSku: searchSku
    deployerPrincipalId: principalId
    deployerPrincipalType: principalType
    deployWebApp: deployWebApp
    resourceGroupName: resourceGroupName
    tags: union(tags, { 'azd-env-name': environmentName })
  }
}

// UPPER_SNAKE_CASE outputs -> .azure/<env>/.env -> postprovision -> demo-ids.local.json
output AZURE_RESOURCE_GROUP string = main.outputs.deploymentSummary.resourceGroup
output STORAGE_ACCOUNT_NAME string = main.outputs.deploymentSummary.storageAccount
output BLOB_ENDPOINT string = main.outputs.deploymentSummary.blobEndpoint
output RAW_CONTAINER string = main.outputs.deploymentSummary.rawContainer
output CHUNKS_CONTAINER string = main.outputs.deploymentSummary.chunksContainer
output KEY_VAULT_NAME string = main.outputs.deploymentSummary.keyVault
output KEY_VAULT_URI string = main.outputs.deploymentSummary.keyVaultUri
output FOUNDRY_RESOURCE_NAME string = main.outputs.deploymentSummary.foundryResource
output FOUNDRY_OPENAI_ENDPOINT string = main.outputs.deploymentSummary.foundryOpenAIEndpoint
output DOCUMENT_INTELLIGENCE_ENDPOINT string = main.outputs.deploymentSummary.documentIntelligenceEndpoint
output EMBEDDING_DEPLOYMENT string = main.outputs.deploymentSummary.embeddingDeployment
output CHAT_DEPLOYMENT string = main.outputs.deploymentSummary.chatDeployment
output CHAT_DEPLOYED bool = main.outputs.deploymentSummary.chatDeployed
output SEARCH_SERVICE_NAME string = main.outputs.deploymentSummary.searchService
output SEARCH_ENDPOINT string = main.outputs.deploymentSummary.searchEndpoint
output SEARCH_PRINCIPAL_ID string = main.outputs.deploymentSummary.searchPrincipalId
output SEARCH_INDEX_NAME string = main.outputs.deploymentSummary.searchIndexName
output SEARCH_DATA_SOURCE_NAME string = main.outputs.deploymentSummary.searchDataSourceName
output SEARCH_INDEXER_NAME string = main.outputs.deploymentSummary.searchIndexerName
output DEPLOYER_HAS_SEARCH_ROLES bool = main.outputs.deploymentSummary.deployerHasSearchRoles
output WEBAPP_DEPLOYED bool = main.outputs.deploymentSummary.webAppDeployed
output WEBAPP_ACR_NAME string = main.outputs.deploymentSummary.webAppAcr
output WEBAPP_ACR_LOGIN_SERVER string = main.outputs.deploymentSummary.webAppAcrLoginServer
output WEBAPP_ENVIRONMENT_NAME string = main.outputs.deploymentSummary.webAppEnvironment
output WEBAPP_IDENTITY_NAME string = main.outputs.deploymentSummary.webAppIdentityName
output WEBAPP_IDENTITY_CLIENT_ID string = main.outputs.deploymentSummary.webAppIdentityClientId
output WEBAPP_IDENTITY_RESOURCE_ID string = main.outputs.deploymentSummary.webAppIdentityResourceId

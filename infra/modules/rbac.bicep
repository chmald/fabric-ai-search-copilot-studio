// =====================================================================================
// modules/rbac.bicep — Role assignments for managed-identity-only auth
// =====================================================================================
//
// API keys are disabled on Foundry, Document Intelligence, AI Search, and Storage
// (shared keys). All data-plane access goes through Entra ID. This module wires the
// machine-to-machine assignments that are deterministic enough to express in Bicep.
//
// Assignments made here:
//   1. AI Search MI → Cognitive Services OpenAI User on Foundry
//      (integrated vectorizer calls embedding deployment with bearer token)
//   2. AI Search MI → Storage Blob Data Reader on Storage
//      (indexer pulls chunk JSON from chunks/ container with bearer token)
//   3. Document Intelligence MI → Storage Blob Data Reader on Storage
//      (DI fetches raw/<file> via urlSource using its own MI — required now that
//      shared key is disabled and the pipeline can't pass a SAS token)
//   4. (Optional, if deployerPrincipalId provided) deployer → Search Service Contributor
//      and Search Index Data Contributor on AI Search
//      (post_deploy_search.py uses the deployer's identity to PUT index / datasource /
//      indexer via bearer token instead of admin keys)
//
// Not made here (manual portal step — see docs/03b-fabric-setup.md):
//   * Fabric workspace identity → Storage Blob Data Contributor on Storage
//     (workspace identity GUID isn't known until the Fabric workspace is created)
//   * Fabric workspace identity → Cognitive Services User on Document Intelligence
//     (same reason — lets the pipeline Web activity call DI with bearer token)
//
// NOTE: This deployment requires User Access Administrator (or Owner) at the
// resource group scope. Contributor alone is NOT sufficient.
// =====================================================================================

@description('AI Search service system-assigned managed identity principal ID.')
param searchPrincipalId string

@description('Document Intelligence system-assigned managed identity principal ID.')
param docIntelPrincipalId string

@description('Storage account name (same RG as this deployment).')
param storageAccountName string

@description('Foundry resource account name (same RG as this deployment).')
param foundryAccountName string

@description('AI Search service name (same RG as this deployment). Required for scoping deployer roles.')
param searchServiceName string

@description('Optional: object ID of the user / service principal running the post-deploy script. When provided, grants Search Service Contributor + Search Index Data Contributor on the AI Search service so the script can authenticate with a bearer token instead of an admin key.')
param deployerPrincipalId string = ''

@description('Principal type for deployerPrincipalId. Set to User for an interactive az login identity, or ServicePrincipal for a CI service principal / managed identity.')
@allowed([
  'User'
  'ServicePrincipal'
])
param deployerPrincipalType string = 'User'

// Well-known role definition IDs (Azure built-in roles).
// The Cognitive Services User role (a97b65f3-...) covers data-plane access to all
// Cognitive Services endpoints under an AIServices/FormRecognizer resource — including
// OpenAI model invocation — and is what this pattern uses for both:
//   * AI Search MI calling the Foundry-hosted OpenAI embedding deployment, and
//   * Fabric workspace identity calling Document Intelligence (granted manually
//     in 03b-fabric-setup.md once the workspace identity exists).
// The narrower role "Cognitive Services OpenAI User" (5e0bd9bd-7b93-4f28-af87-19fc36ad61bd)
// is equally acceptable for the Foundry OpenAI use case and may be preferred if your
// security baseline requires least-privilege role scoping.
var roleIds = {
  cognitiveServicesUser:        'a97b65f3-24c7-4388-baec-2e87135dc908'
  storageBlobDataReader:        '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  searchServiceContributor:     '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  searchIndexDataContributor:   '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  // Reference (not assigned here):
  //   Storage Blob Data Contributor    = ba92f5b4-2d11-453d-a403-e96b0029c9fe
  //   Cognitive Services OpenAI User   = 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd
}

// Resource references (existing — created by sibling modules)
resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

resource searchSvc 'Microsoft.Search/searchServices@2024-03-01-preview' existing = {
  name: searchServiceName
}

// =====================================================================================
// AI Search MI -> Cognitive Services User on Foundry
// (Integrated vectorizer calls embedding deployment with a bearer token.)
// =====================================================================================
resource searchToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, searchPrincipalId, roleIds.cognitiveServicesUser)
  properties: {
    principalId: searchPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesUser)
  }
}

// =====================================================================================
// AI Search MI -> Storage Blob Data Reader on Storage account
// =====================================================================================
resource searchToStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, searchPrincipalId, roleIds.storageBlobDataReader)
  properties: {
    principalId: searchPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataReader)
  }
}

// =====================================================================================
// Document Intelligence MI -> Storage Blob Data Reader on Storage account
// (Lets DI fetch raw/<file> via urlSource using its own MI — mandatory now that
//  shared-key access is disabled.)
// =====================================================================================
resource diToStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, docIntelPrincipalId, roleIds.storageBlobDataReader)
  properties: {
    principalId: docIntelPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataReader)
  }
}

// =====================================================================================
// (Optional) deployer -> Search Service Contributor + Search Index Data Contributor
// on the AI Search service. Required for post_deploy_search.py to authenticate with
// a bearer token instead of an admin key.
// =====================================================================================
resource deployerToSearchService 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: searchSvc
  name: guid(searchSvc.id, deployerPrincipalId, roleIds.searchServiceContributor)
  properties: {
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchServiceContributor)
  }
}

resource deployerToSearchIndexData 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: searchSvc
  name: guid(searchSvc.id, deployerPrincipalId, roleIds.searchIndexDataContributor)
  properties: {
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchIndexDataContributor)
  }
}

output searchToFoundryAssignmentId string = searchToFoundry.id
output searchToStorageAssignmentId string = searchToStorage.id
output diToStorageAssignmentId string = diToStorage.id
output deployerToSearchServiceAssignmentId string = empty(deployerPrincipalId) ? '' : deployerToSearchService.id
output deployerToSearchIndexDataAssignmentId string = empty(deployerPrincipalId) ? '' : deployerToSearchIndexData.id

// =====================================================================================
// modules/rbac.bicep — Role assignments for AI Search managed identity
// =====================================================================================
//
// The two critical role assignments for the pattern:
//   1. AI Search MI -> Cognitive Services OpenAI User on the Foundry resource
//      (lets the integrated vectorizer call the embedding deployment)
//   2. AI Search MI -> Storage Blob Data Reader on the Storage account
//      (lets the indexer pull chunk JSON from the chunks/ container)
//
// Without these the indexer fails with cryptic 403s. This module makes the
// assignments deterministic + repeatable via Bicep.
//
// NOTE: This deployment requires User Access Administrator (or Owner) at the
// resource group scope. Contributor alone is NOT sufficient.
// =====================================================================================

@description('AI Search service system-assigned managed identity principal ID.')
param searchPrincipalId string

@description('Storage account name (same RG as this deployment).')
param storageAccountName string

@description('Foundry resource account name (same RG as this deployment).')
param foundryAccountName string

// Well-known role definition IDs (Azure built-in roles)
var roleIds = {
  cognitiveServicesOpenAIUser: 'a97b65f3-24c7-4388-baec-2e87135dc908'
  storageBlobDataReader:       '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  // Reference (not assigned here): Storage Blob Data Contributor = ba92f5b4-2d11-453d-a403-e96b0029c9fe
}

// Resource references (existing — created by sibling modules)
resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

// =====================================================================================
// AI Search MI -> Cognitive Services OpenAI User on Foundry
// =====================================================================================
resource searchToFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, searchPrincipalId, roleIds.cognitiveServicesOpenAIUser)
  properties: {
    principalId: searchPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesOpenAIUser)
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

output searchToFoundryAssignmentId string = searchToFoundry.id
output searchToStorageAssignmentId string = searchToStorage.id

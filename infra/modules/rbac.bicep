// =====================================================================================
// modules/rbac.bicep — Role assignments for managed-identity-only auth
// =====================================================================================
//
// API keys are disabled on Foundry and AI Search (and Storage shared keys). All
// data-plane access goes through Entra ID. This module wires the machine-to-machine
// assignments that are deterministic enough to express in Bicep.
//
// Architectural note: this pattern uses a SINGLE Foundry resource (kind=AIServices)
// to serve both Azure OpenAI (embeddings + chat) and Document Intelligence
// (prebuilt-read OCR). There is no separate Microsoft.CognitiveServices/accounts
// of kind=FormRecognizer — the Foundry account's MI is the same identity that DI
// uses to fetch blobs via `urlSource`, so a single Storage Blob Data Reader grant
// covers both the OpenAI and DI code paths.
//
// Assignments made here:
//   1. AI Search MI → Cognitive Services OpenAI User on Foundry
//      (integrated vectorizer calls embedding deployment with bearer token)
//   2. AI Search MI → Storage Blob Data Reader on Storage
//      (indexer pulls chunk JSON from chunks/ container with bearer token)
//   3. Foundry MI → Storage Blob Data Reader on Storage
//      (Document Intelligence inside the Foundry account fetches raw/<file> via
//      urlSource using the Foundry account's MI — required now that shared key
//      is disabled and the pipeline can't pass a SAS token)
//   4. (Optional, if deployerPrincipalId provided) deployer → Search Service Contributor
//      and Search Index Data Contributor on AI Search
//      (post_deploy_search.py uses the deployer's identity to PUT index / datasource /
//      indexer via bearer token instead of admin keys)
//
// Not made here (manual portal step — see docs/03b-fabric-setup.md):
//   * Fabric workspace identity → Storage Blob Data Contributor on Storage
//     (workspace identity GUID isn't known until the Fabric workspace is created)
//   * DI-caller service principal → Cognitive Services User on the Foundry resource
//     (lets the Fabric notebook call DI via MSAL with a bearer token — same role
//     as before, just scoped to Foundry now that there is no standalone DI account)
//
// NOTE: This deployment requires User Access Administrator (or Owner) at the
// resource group scope. Contributor alone is NOT sufficient.
// =====================================================================================

@description('AI Search service system-assigned managed identity principal ID.')
param searchPrincipalId string

@description('Foundry resource system-assigned managed identity principal ID. Granted Storage Blob Data Reader so Document Intelligence (served from the same Foundry account) can fetch raw/<file> via urlSource.')
param foundryPrincipalId string

@description('Storage account name (same RG as this deployment).')
param storageAccountName string

@description('Foundry resource account name (same RG as this deployment).')
param foundryAccountName string

@description('AI Search service name (same RG as this deployment). Required for scoping deployer roles.')
param searchServiceName string

@description('Key Vault name (same RG as this deployment). Required for scoping the deployer\'s Key Vault Secrets Officer role.')
param keyVaultName string

@description('Optional: object ID of the user / service principal running the post-deploy script. When provided, grants Search Service Contributor + Search Index Data Contributor on the AI Search service so the script can authenticate with a bearer token instead of an admin key.')
param deployerPrincipalId string = ''

@description('Principal type for deployerPrincipalId. Set to User for an interactive az login identity, or ServicePrincipal for a CI service principal / managed identity.')
@allowed([
  'User'
  'ServicePrincipal'
])
param deployerPrincipalType string = 'User'

// Well-known role definition IDs (Azure built-in roles).
//
// IMPORTANT: For the AI Search integrated vectorizer to call an Azure OpenAI / Foundry
// embedding deployment, the search MI MUST have **Cognitive Services OpenAI User**
// (5e0bd9bd-...). The narrower / similarly-named **Cognitive Services User**
// (a97b65f3-...) is for non-OpenAI Cognitive Services (Document Intelligence, Translator,
// Vision, etc.) and does NOT grant OpenAI data-plane access on a Foundry resource.
// Using Cognitive Services User here causes the indexer to succeed but every document
// to be committed with a null `content_vector` (vectorIndexSize=0). See
// docs/06-troubleshooting.md § 4.1 for the silent-failure signature.
//
// References:
//   https://learn.microsoft.com/azure/search/vector-search-vectorizer-azure-open-ai#vectorizer-parameters
//   https://learn.microsoft.com/azure/search/vector-search-how-to-configure-vectorizer#troubleshooting
var roleIds = {
  cognitiveServicesOpenAIUser:  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  storageBlobDataReader:        '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
  searchServiceContributor:     '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  searchIndexDataContributor:   '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  keyVaultSecretsOfficer:       'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  // Reference (not assigned here):
  //   Storage Blob Data Contributor    = ba92f5b4-2d11-453d-a403-e96b0029c9fe
  //   Cognitive Services User          = a97b65f3-24c7-4388-baec-2e87135dc908  (DO NOT use for OpenAI vectorizer)
  //   Key Vault Secrets User           = 4633458b-17de-408a-b874-0445c86b69e6  (read-only secret access — used by Fabric workspace identity at runtime)
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

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

// =====================================================================================
// AI Search MI -> Cognitive Services OpenAI User on Foundry
// (Integrated vectorizer calls embedding deployment with a bearer token.
//  Using the wrong role here — e.g. plain "Cognitive Services User" — causes the
//  indexer to silently produce documents with null content_vector. See
//  docs/06-troubleshooting.md § 4.1.)
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

// =====================================================================================
// Foundry MI -> Storage Blob Data Reader on Storage account
// (Document Intelligence runs inside the Foundry account — it uses the Foundry MI
//  to fetch raw/<file> via urlSource. Mandatory now that shared-key access is
//  disabled on Storage.)
// =====================================================================================
resource foundryToStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, foundryPrincipalId, roleIds.storageBlobDataReader)
  properties: {
    principalId: foundryPrincipalId
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

// =====================================================================================
// (Optional) deployer -> Key Vault Secrets Officer on the Key Vault.
// Lets the deployer (operator running 03b-fabric-setup.md § F2.2 step 3, or any
// later step that creates/rotates secrets in the vault) write the DI-caller SP
// secret (and any future connector credentials). Without this assignment, the
// `az keyvault secret set` call in F2.2 step 3 fails with `403 Forbidden`.
// =====================================================================================
resource deployerToKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: keyVault
  name: guid(keyVault.id, deployerPrincipalId, roleIds.keyVaultSecretsOfficer)
  properties: {
    principalId: deployerPrincipalId
    principalType: deployerPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsOfficer)
  }
}

output searchToFoundryAssignmentId string = searchToFoundry.id
output searchToStorageAssignmentId string = searchToStorage.id
output foundryToStorageAssignmentId string = foundryToStorage.id
output deployerToSearchServiceAssignmentId string = empty(deployerPrincipalId) ? '' : deployerToSearchService.id
output deployerToSearchIndexDataAssignmentId string = empty(deployerPrincipalId) ? '' : deployerToSearchIndexData.id
output deployerToKeyVaultAssignmentId string = empty(deployerPrincipalId) ? '' : deployerToKeyVault.id

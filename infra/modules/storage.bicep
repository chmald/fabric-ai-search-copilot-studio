// =====================================================================================
// modules/storage.bicep — Storage account + blob containers
// =====================================================================================

@description('Storage account name (3-24 chars, lowercase alphanumeric only).')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Storage SKU. Standard_LRS for demo, Standard_GRS+ for production durability.')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
])
param sku string = 'Standard_LRS'

@description('Names of blob containers to create.')
param containers array = []

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // Shared-key (account key) access is disabled — all data-plane access goes through
    // Entra ID. The AI Search indexer authenticates via its system-assigned managed
    // identity (Storage Blob Data Reader role); the Fabric workspace identity
    // authenticates via Storage Blob Data Contributor; Document Intelligence reads the
    // raw blob URLs via its system-assigned managed identity (Storage Blob Data
    // Reader). User-delegated SAS tokens generated against AAD are still supported.
    allowSharedKeyAccess: false
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource containerResources 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = [for c in containers: {
  parent: blobService
  name: c
  properties: {
    publicAccess: 'None'
  }
}]

output id string = storage.id
output name string = storage.name
output blobEndpoint string = storage.properties.primaryEndpoints.blob

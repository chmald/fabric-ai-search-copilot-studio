// =====================================================================================
// modules/keyvault.bicep — Azure Key Vault (RBAC mode)
// =====================================================================================

@description('Key Vault name (3-24 chars, lowercase alphanumeric and hyphens).')
@minLength(3)
@maxLength(24)
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Enable purge protection. Recommended ON for production; OFF for demo to allow clean teardown.')
param enablePurgeProtection bool = false

@description('Soft-delete retention in days.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionDays int = 7

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionDays
    enablePurgeProtection: enablePurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

output id string = keyVault.id
output name string = keyVault.name
output uri string = keyVault.properties.vaultUri

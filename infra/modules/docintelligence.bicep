// =====================================================================================
// modules/docintelligence.bicep — Azure Document Intelligence (kind=FormRecognizer)
// =====================================================================================
//
// Document Intelligence is a sibling of AI Foundry — both are Cognitive Services accounts
// with different `kind` values. This pattern uses the `prebuilt-read` model for OCR — no
// custom training required.
// =====================================================================================

@description('Document Intelligence resource name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object = {}

@description('SKU. F0 = free tier (500 pages/month, demo only). S0 = standard.')
@allowed([
  'F0'
  'S0'
])
param sku string = 'S0'

resource docIntel 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'FormRecognizer'
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
    // API keys disabled — Document Intelligence is called from the Fabric pipeline
    // using the workspace identity with role "Cognitive Services User" on this
    // resource (Entra bearer token, resource = https://cognitiveservices.azure.com/).
    disableLocalAuth: true
  }
}

output id string = docIntel.id
output name string = docIntel.name
output endpoint string = docIntel.properties.endpoint
output systemAssignedPrincipalId string = docIntel.identity.principalId

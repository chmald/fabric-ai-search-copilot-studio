// =====================================================================================
// modules/aifoundry.bicep — Azure AI Foundry resource (kind=AIServices) + model deployments
// =====================================================================================
//
// Provisions:
//   * Foundry resource (Microsoft.CognitiveServices/accounts, kind=AIServices) with system-assigned MI
//   * Embedding model deployment (text-embedding-3-large by default)
//   * Chat model deployment (gpt-4o by default)
//
// Foundry resource exposes an OpenAI-compatible endpoint at https://<name>.openai.azure.com
// — used directly by AI Search's integrated azureOpenAI vectorizer.
//
// This pattern uses Foundry's MODEL GATEWAY capability only. Foundry's agent runtime
// (Agent Service / Hub / Projects) is NOT used here — Copilot Studio's native AI Search
// knowledge source fills the agent role for knowledge-base Q&A. Foundry agent runtime
// is the right addition when an engagement requires multi-agent routing, custom tool
// calling, or query triage; that is an engagement-specific decision, not part of this
// pattern's default stack.
// =====================================================================================

@description('Foundry resource name.')
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object = {}

@description('Embedding model name (Azure OpenAI catalog).')
param embeddingModelName string = 'text-embedding-3-large'

@description('Embedding model version. Leave blank to let Azure pick latest GA.')
param embeddingModelVersion string = ''

@description('Embedding deployment TPM capacity in units of 1000.')
@minValue(1)
param embeddingModelTpm int = 10

@description('Chat model name (Azure OpenAI catalog).')
param chatModelName string = 'gpt-4o'

@description('Chat model version. Leave blank to let Azure pick latest GA.')
param chatModelVersion string = ''

@description('Chat deployment TPM capacity in units of 1000.')
@minValue(1)
param chatModelTpm int = 10

resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
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
    disableLocalAuth: false
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: 'embedding'
  sku: {
    name: 'Standard'
    capacity: embeddingModelTpm
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: empty(embeddingModelVersion) ? null : embeddingModelVersion
    }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: foundry
  name: 'chat'
  sku: {
    name: 'Standard'
    capacity: chatModelTpm
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: empty(chatModelVersion) ? null : chatModelVersion
    }
    raiPolicyName: 'Microsoft.DefaultV2'
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
  // Chat deployment is created after embedding to serialize the two deployments
  // (sequential deployment avoids transient 429s on the deployments endpoint)
  dependsOn: [
    embeddingDeployment
  ]
}

output id string = foundry.id
output name string = foundry.name
output openAIEndpoint string = 'https://${foundry.properties.customSubDomainName}.openai.azure.com'
output cognitiveServicesEndpoint string = foundry.properties.endpoint
output systemAssignedPrincipalId string = foundry.identity.principalId
output embeddingDeploymentName string = embeddingDeployment.name
output chatDeploymentName string = chatDeployment.name

// =====================================================================================
// modules/aifoundry.bicep — Microsoft Foundry resource (kind=AIServices) + model deployments
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
// (Agent Service and projects) is NOT used here — Copilot Studio's native AI Search
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

@description('Chat model name (Azure OpenAI catalog). Leave EMPTY to skip the chat deployment entirely — the default locked design (Copilot Studio + AI Search hybrid index + integrated vectorizer) does NOT consume a chat completion model, because Copilot Studio uses its own host model for generative answers. Only set this when you have an explicit engagement-specific need: custom app code calling completions, Foundry agent runtime, or a Copilot Studio bring-your-own-model configuration.')
param chatModelName string = ''

@description('Chat model version. Leave blank to let Azure pick latest GA. Ignored when chatModelName is empty.')
param chatModelVersion string = ''

@description('Chat deployment TPM capacity in units of 1000. Ignored when chatModelName is empty.')
@minValue(1)
param chatModelTpm int = 10

@description('Set to true ONLY when an existing Foundry account with the same name is in Azure soft-delete state and you want Bicep to restore it in place (preserves the system-assigned MI principal ID and any role assignments granted to it). Default false. CAUTION: when this is true and there is no soft-deleted account to restore, the deploy fails with `CanNotRestoreANonExistingResource`. Set this to true only after a deploy fails with `FlagMustBeSetForRestore`. See docs/06-troubleshooting.md § 0.5.')
param restoreFromSoftDelete bool = false

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
  // Build the properties bag with a conditional `restore` property. Bicep has no
  // spread operator, so we use union() to splice the optional flag in only when
  // restoreFromSoftDelete is true. ARM rejects `restore: true` on a fresh CREATE
  // (CanNotRestoreANonExistingResource), so it MUST NOT be in the body unless we
  // actually have a soft-deleted resource to restore from.
  properties: union({
    customSubDomainName: name
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
    // API keys are disabled — all clients (AI Search vectorizer, app code) must use
    // Entra ID bearer tokens via managed identity / service principal. Grant the
    // calling identity "Cognitive Services OpenAI User" (OpenAI model access) or
    // "Cognitive Services User" (broader catalog) on this resource.
    disableLocalAuth: true
  }, restoreFromSoftDelete ? {
    // Restore an existing soft-deleted account in place. Preserves the MI principal
    // ID and any role assignments granted to it — critical here because the
    // DI-caller SP's "Cognitive Services User" role on this resource is granted
    // manually (docs/03b-fabric-setup.md § F2.2 step 2) and would be orphaned by
    // a purge-and-recreate cycle.
    // Reference: https://learn.microsoft.com/azure/ai-services/recover-purge-resources
    restore: true
  } : {})
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

// Optional chat completion deployment. The locked design (Copilot Studio + AI Search
// hybrid index + integrated vectorizer) does NOT consume a chat completion model —
// Copilot Studio uses its own host model for generative answers. Only provisioned
// when chatModelName is non-empty (engagement-specific opt-in: custom app code,
// Foundry agent runtime, or Copilot Studio bring-your-own-model).
resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (!empty(chatModelName)) {
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
output chatDeploymentName string = empty(chatModelName) ? '' : chatDeployment.name

// =====================================================================================
// modules/search.bicep — Azure AI Search Standard (semantic ranker enabled)
// =====================================================================================
//
// Standard (S1) or higher is REQUIRED — semantic ranker is not available on Free or Basic.
// System-assigned managed identity is enabled so the indexer can authenticate to Blob
// and the integrated vectorizer can authenticate to the Foundry OpenAI endpoint.
//
// This module provisions the SERVICE only. The index, data source, and indexer are
// configured by scripts/post_deploy_search.py via REST after deployment because the
// Microsoft.Search/searchServices/indexes ARM resource type does not cleanly express
// integrated vectorizer config + semantic configuration + the indexer's field-mapping
// surface.
// =====================================================================================

@description('AI Search service name (lowercase alphanumeric and hyphens, must be globally unique).')
@minLength(2)
@maxLength(60)
param name string

@description('Azure region.')
param location string

@description('Resource tags.')
param tags object = {}

@description('SKU. Standard (S1) MINIMUM for semantic ranker. Free/Basic are NOT supported by this pattern.')
@allowed([
  'standard'
  'standard2'
  'standard3'
])
param sku string = 'standard'

@description('Replica count. 1 for demo, 2+ for production read availability.')
@minValue(1)
@maxValue(12)
param replicaCount int = 1

@description('Partition count. Scale up for index size beyond ~25 GB per partition.')
@minValue(1)
@maxValue(12)
param partitionCount int = 1

@description('Semantic ranker plan. "free" = 1000 queries/month included; "standard" = metered beyond free tier.')
@allowed([
  'disabled'
  'free'
  'standard'
])
param semanticSearch string = 'free'

resource search 'Microsoft.Search/searchServices@2024-03-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: replicaCount
    partitionCount: partitionCount
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    semanticSearch: semanticSearch
    networkRuleSet: {
      ipRules: []
    }
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    // Entra-only auth. With `disableLocalAuth: true`, admin and query API keys are
    // rejected and every caller must use a bearer token. The Azure Search API requires
    // `authOptions` to be NULL when `disableLocalAuth` is true (the two are mutually
    // exclusive — setting both returns `BadRequest: AuthOptions must be null if
    // DisableLocalAuth is true`). Unauthenticated requests still receive a proper 401
    // with a `WWW-Authenticate: Bearer ...` challenge — that is the default behaviour
    // when local auth is disabled and does not need to be opted in via `authOptions`.
    //
    // Required roles for callers (granted in modules/rbac.bicep or 03-deployment-manual.md § 1.7):
    //   * Search Service Contributor   — create/manage indexes, datasources, indexers
    //   * Search Index Data Contributor — write documents to an index
    //   * Search Index Data Reader     — read/query documents
    disableLocalAuth: true
  }
}

output id string = search.id
output name string = search.name
output endpoint string = 'https://${search.name}.search.windows.net'
output systemAssignedPrincipalId string = search.identity.principalId

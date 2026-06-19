// =====================================================================================
// modules/containerapp.bicep — Optional web-app hosting platform (Container Apps)
// =====================================================================================
//
// Provisions the platform the chat front end (webapp/app) runs on. It deliberately
// does NOT create the Container App resource itself — the application image is built
// from source and deployed by scripts/deploy-webapp.ps1 via `az acr build` + `az containerapp create/update`,
// which avoids the image-before-app ordering problem and keeps the app build out of
// the ARM/Bicep control plane. This module owns only the durable platform:
//
//   * Log Analytics workspace      (Container Apps environment diagnostics)
//   * Container Apps environment    (consumption workload profile)
//   * Azure Container Registry      (Basic, admin user disabled — pull via MI)
//   * User-assigned managed identity (the app's runtime identity)
//   * Role assignments:
//        - app MI -> AcrPull on the registry (pull the built image)
//        - app MI -> Foundry User on Foundry (invoke the agent / project)
//        - app MI -> Cognitive Services OpenAI Contributor on Foundry
//          (covers direct Azure OpenAI model calls in addition to agent invocation)
//
// Identity model:
//   * MI mode  — the app calls the agent as this managed identity.
//   * OBO mode — the app calls the agent on behalf of the signed-in user; this
//                managed identity is also the federated client assertion source
//                for the secretless On-Behalf-Of exchange. The Entra app
//                registration + federated identity credential + admin consent for
//                OBO are created by scripts/deploy-webapp.ps1 (not expressible in
//                Bicep). See docs/08 and docs/09.
//
// NOTE: Role assignments require User Access Administrator (or Owner) at the
// resource group scope — Contributor alone is NOT sufficient (same as rbac.bicep).
//
// VERIFY AT DEPLOY TIME: Foundry data-plane roles were renamed under Foundry
// branding (Azure AI User -> Foundry User, etc.). Per the Foundry RBAC docs, the
// "Azure AI Developer" role is NOT used for Foundry projects/agents (it is scoped to
// Azure ML workspaces and Foundry hubs); agent/project access uses **Foundry User**.
// Confirm current names/IDs against Microsoft Learn (docs/09 § RBAC). GUIDs below are
// the current built-in IDs.
// =====================================================================================

@description('Azure Container Registry name (globally unique, alphanumeric, 5-50 chars).')
param acrName string

@description('Container Apps environment name.')
param environmentName string

@description('Log Analytics workspace name backing the Container Apps environment.')
param logAnalyticsName string

@description('User-assigned managed identity name for the web app runtime.')
param identityName string

@description('Azure region for all resources.')
param location string

@description('Tags applied to all resources.')
param tags object

@description('Foundry resource account name (same RG). The app MI is granted data-plane roles here so it can invoke the agent.')
param foundryAccountName string

// Built-in role definition IDs.
var roleIds = {
  acrPull:                          '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  foundryUser:                      '53ca6127-db72-4b80-b1b0-d745d6d5456d'
  cognitiveServicesOpenAIContributor: 'a001fd3d-188f-4b5d-821b-7da978bf7442'
}

// --- Log Analytics ------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// --- Container Apps environment -----------------------------------------------
resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

// --- Azure Container Registry -------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

// --- App runtime managed identity ---------------------------------------------
resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

// --- Existing Foundry account (created by aifoundry.bicep) ---------------------
resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: foundryAccountName
}

// --- Role assignments ---------------------------------------------------------

// app MI -> AcrPull on the registry
resource appToAcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, appIdentity.id, roleIds.acrPull)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.acrPull)
  }
}

// app MI -> Foundry User on Foundry (invoke the agent / use the project)
resource appToFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, appIdentity.id, roleIds.foundryUser)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.foundryUser)
  }
}

// app MI -> Cognitive Services OpenAI Contributor on Foundry (direct model calls)
resource appToFoundryOpenAI 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: foundry
  name: guid(foundry.id, appIdentity.id, roleIds.cognitiveServicesOpenAIContributor)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesOpenAIContributor)
  }
}

// --- Outputs ------------------------------------------------------------------
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output environmentName string = cae.name
output environmentId string = cae.id
output identityName string = appIdentity.name
output identityClientId string = appIdentity.properties.clientId
output identityPrincipalId string = appIdentity.properties.principalId
output identityResourceId string = appIdentity.id

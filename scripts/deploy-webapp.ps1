<#
.SYNOPSIS
  Build and deploy the chat front end (webapp/app) onto the Container Apps platform
  provisioned by infra/main.bicep (deployWebApp=true), connected to a published
  Microsoft Foundry agent.

.DESCRIPTION
  This is the single web-app deploy step for the pattern. It does NOT contain
  application code — the app lives in webapp/app and is built from source in Azure
  Container Registry (no local Docker required). Steps:

    1. Resolve platform identifiers (ACR, Container Apps environment, managed
       identity) from the Bicep deploymentSummary in demo-ids.local.json, or from
       explicit parameters.
    2. Build the image with `az acr build`.
    3. Create/update the Container App with the user-assigned managed identity,
       managed-identity ACR pull, ingress, and the runtime env vars.
    4. (Default) MI mode — the app calls the agent as its managed identity.
       (-EnableObo) Also configure secretless On-Behalf-Of: an Entra app
       registration + federated identity credential + Container Apps authentication
       so the app calls the agent as the signed-in user (required for the Microsoft
       Fabric data agent tool). See docs/08 and docs/09.

  The agent's PROJECT endpoint and AGENT ID come from the Foundry agent you build in
  docs/03d (a portal/preview step), so they are passed in here — they are not part of
  the Bicep output.

.PARAMETER FoundryProjectEndpoint
  Foundry project endpoint, e.g.
  https://<resource>.services.ai.azure.com/api/projects/<project>

.PARAMETER AgentId
  Published agent identifier from docs/03d (e.g. "hr-knowledge-agent").

.PARAMETER IdsFile
  Path to the Bicep output file (default demo-ids.local.json) used to resolve the
  resource group, ACR, Container Apps environment, and managed identity.

.PARAMETER AppName
  Container App name (default: app-<workload>-web derived from the ids file, else
  "app-rag-web").

.PARAMETER EnableObo
  Configure On-Behalf-Of (Entra app registration + federated credential + Container
  Apps authentication). Required for the Microsoft Fabric data agent tool.

.PARAMETER WhatIf
  Print the az commands without executing changes.

.EXAMPLE
  pwsh ./scripts/deploy-webapp.ps1 `
     -FoundryProjectEndpoint "https://acme.services.ai.azure.com/api/projects/kb" `
     -AgentId "knowledge-agent"

.EXAMPLE
  # With user-identity passthrough (Fabric tool)
  pwsh ./scripts/deploy-webapp.ps1 -FoundryProjectEndpoint $ep -AgentId $id -EnableObo
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FoundryProjectEndpoint,
    [Parameter(Mandatory = $true)][string]$AgentId,
    [string]$IdsFile = "demo-ids.local.json",
    [string]$AppName,
    [string]$AgentTokenScope = "https://ai.azure.com/.default",
    [switch]$EnableObo,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$repoRoot = Split-Path $PSScriptRoot -Parent
$appSource = Join-Path $repoRoot "webapp/app"

function Invoke-Az {
    param([string[]]$AzArgs, [switch]$Quiet)
    Write-Host "  az $($AzArgs -join ' ')" -ForegroundColor DarkGray
    if ($WhatIf) { return $null }
    if ($Quiet) { return (az @AzArgs 2>$null) }
    return (az @AzArgs)
}

# --- Preconditions ----------------------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI ('az') not found. Install per https://learn.microsoft.com/cli/azure/install-azure-cli"
}
if (-not (Test-Path $appSource)) {
    Write-Error "App source not found at $appSource."
}

# --- Resolve platform identifiers -------------------------------------------
$rg = $null; $acrName = $null; $acrLogin = $null; $envName = $null
$uamiResourceId = $null; $uamiClientId = $null; $workload = "rag"

if (Test-Path (Join-Path $repoRoot $IdsFile)) {
    $ids = Get-Content (Join-Path $repoRoot $IdsFile) -Raw | ConvertFrom-Json
    $rg = $ids.resourceGroup
    $acrName = $ids.webAppAcr
    $acrLogin = $ids.webAppAcrLoginServer
    $envName = $ids.webAppEnvironment
    $uamiResourceId = $ids.webAppIdentityResourceId
    $uamiClientId = $ids.webAppIdentityClientId
    if ($ids.workload) { $workload = $ids.workload }
}

if (-not $acrName -or -not $envName -or -not $uamiResourceId) {
    Write-Error @"
Could not resolve the web-app platform from $IdsFile.
Deploy the platform first:
    pwsh ./infra/deploy.ps1 -ParameterFile infra/main.parameters.local.json   # with deployWebApp=true
Ensure infra/main.parameters.local.json sets deployWebApp = true, then re-run this script.
"@
}

if (-not $AppName) { $AppName = "app-$workload-web" }
$tenantId = (az account show --query tenantId -o tsv)
$imageTag = Get-Date -Format "yyyyMMddHHmm"
$image = "rag-webapp:$imageTag"

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " Foundry agent web app — build + deploy" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host (" Resource group : {0}" -f $rg)
Write-Host (" Container App  : {0}" -f $AppName)
Write-Host (" Environment    : {0}" -f $envName)
Write-Host (" Registry       : {0}" -f $acrLogin)
Write-Host (" App identity   : {0}" -f $uamiClientId)
Write-Host (" Agent endpoint : {0}" -f $FoundryProjectEndpoint)
Write-Host (" Identity mode  : {0}" -f ($(if ($EnableObo) { 'OBO (per-user passthrough)' } else { 'Managed identity' })))
Write-Host ""

# --- 1. Build the image in ACR ----------------------------------------------
Write-Host "Building image in ACR (no local Docker required)..." -ForegroundColor Yellow
Invoke-Az -AzArgs @('acr','build','--registry',$acrName,'--image',$image,$appSource) | Out-Null

# --- 2. Runtime env vars -----------------------------------------------------
$envVars = @(
    "FOUNDRY_PROJECT_ENDPOINT=$FoundryProjectEndpoint",
    "AGENT_ID=$AgentId",
    "AZURE_CLIENT_ID=$uamiClientId",
    "AGENT_TOKEN_SCOPE=$AgentTokenScope"
)
if ($EnableObo) {
    $envVars += "ENABLE_OBO=true"
    $envVars += "AZURE_TENANT_ID=$tenantId"
    # OBO_CLIENT_ID is appended after the app registration is created (step 4).
}

# --- 3. Create or update the Container App ----------------------------------
$exists = $false
if (-not $WhatIf) {
    $exists = [bool](az containerapp show --name $AppName --resource-group $rg --query id -o tsv 2>$null)
}

if ($exists) {
    Write-Host "Updating existing Container App..." -ForegroundColor Yellow
    $updateArgs = @('containerapp','update','--name',$AppName,'--resource-group',$rg,
        '--image',"$acrLogin/$image",'--set-env-vars') + $envVars
    Invoke-Az -AzArgs $updateArgs | Out-Null
} else {
    Write-Host "Creating Container App..." -ForegroundColor Yellow
    $createArgs = @('containerapp','create','--name',$AppName,'--resource-group',$rg,
        '--environment',$envName,'--image',"$acrLogin/$image",
        '--user-assigned',$uamiResourceId,
        '--registry-server',$acrLogin,'--registry-identity',$uamiResourceId,
        '--target-port','8000','--ingress','external','--min-replicas','1',
        '--env-vars') + $envVars
    Invoke-Az -AzArgs $createArgs | Out-Null
}

# --- 4. (Optional) On-Behalf-Of configuration -------------------------------
if ($EnableObo) {
    Write-Host ""
    Write-Host "Configuring On-Behalf-Of (secretless)..." -ForegroundColor Yellow

    # 4a. App registration (confidential client for the OBO exchange).
    $appDisplay = "$AppName-obo"
    $appId = az ad app list --display-name $appDisplay --query "[0].appId" -o tsv 2>$null
    if (-not $appId -and -not $WhatIf) {
        $appId = az ad app create --display-name $appDisplay --query appId -o tsv
    }
    Write-Host ("  App registration : {0}" -f $appId)

    # 4b. Identifier URI so Easy Auth tokens carry an exchangeable audience.
    Invoke-Az -AzArgs @('ad','app','update','--id',$appId,'--identifier-uris',"api://$appId") | Out-Null

    # 4c. Federated identity credential: let the user-assigned MI act as the
    #     confidential client (no secret). Subject = the MI client ID.
    $ficName = "webapp-mi-obo"
    $ficJson = @{
        name      = $ficName
        issuer    = "https://login.microsoftonline.com/$tenantId/v2.0"
        subject   = $uamiClientId
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress
    $ficTmp = New-TemporaryFile
    Set-Content -Path $ficTmp.FullName -Value $ficJson -Encoding utf8
    Invoke-Az -AzArgs @('ad','app','federated-credential','create','--id',$appId,'--parameters',"@$($ficTmp.FullName)") | Out-Null
    Remove-Item $ficTmp.FullName -Force -ErrorAction SilentlyContinue

    # 4d. Push OBO_CLIENT_ID to the app.
    Invoke-Az -AzArgs @('containerapp','update','--name',$AppName,'--resource-group',$rg,
        '--set-env-vars',"OBO_CLIENT_ID=$appId") | Out-Null

    # 4e. Container Apps authentication (Easy Auth) so users sign in and a token
    #     is injected for the OBO exchange.
    Invoke-Az -AzArgs @('containerapp','auth','microsoft','update','--name',$AppName,'--resource-group',$rg,
        '--client-id',$appId,'--issuer',"https://login.microsoftonline.com/$tenantId/v2.0",'--yes') | Out-Null
    Invoke-Az -AzArgs @('containerapp','auth','update','--name',$AppName,'--resource-group',$rg,
        '--action','RequireAuthentication','--redirect-provider','AzureActiveDirectory') | Out-Null

    Write-Host ""
    Write-Host "  MANUAL OBO STEPS — verify against docs/09 and current Microsoft Learn:" -ForegroundColor Magenta
    Write-Host "   * Add a DELEGATED permission on app $appId for the Foundry data plane" -ForegroundColor Magenta
    Write-Host "     (Azure AI / Cognitive Services user_impersonation) and grant ADMIN CONSENT." -ForegroundColor Magenta
    Write-Host "   * Grant each end user a Foundry data-plane role (e.g. Azure AI User) and the" -ForegroundColor Magenta
    Write-Host "     required Fabric Read on the data agent + sources (docs/03e, docs/08)." -ForegroundColor Magenta
    Write-Host "   The exact downstream API app ID + scope vary by tenant/preview — do not guess." -ForegroundColor Magenta
}

# --- 5. Report ---------------------------------------------------------------
if (-not $WhatIf) {
    $fqdn = az containerapp show --name $AppName --resource-group $rg --query "properties.configuration.ingress.fqdn" -o tsv 2>$null
    Write-Host ""
    Write-Host "Deployed." -ForegroundColor Green
    if ($fqdn) { Write-Host (" App URL: https://{0}" -f $fqdn) -ForegroundColor Green }
    Write-Host " Validate per docs/09 § Validate (document Q, structured Q, two-user RLS in OBO mode)." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "-WhatIf: no changes made." -ForegroundColor Yellow
}


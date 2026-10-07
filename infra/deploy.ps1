<#
.SYNOPSIS
  Deploys the RAG Knowledge-Base Pattern Bicep template at subscription scope, then
  runs the post-deploy AI Search configuration script.

.DESCRIPTION
  Convenience wrapper around `az deployment sub create` + `python scripts/post_deploy_search.py`.

  Steps:
    1. (Optional) Run `az deployment sub what-if` for a dry-run preview
    2. Run `az deployment sub create` with main.bicep at subscription scope
    3. Write the deployment outputs to demo-ids.local.json
    4. (Optional) Run scripts/post_deploy_search.py to configure AI Search index + indexer
    5. (Optional) Run --Verify smoke tests

.PARAMETER ParameterFile
  Path to the Bicep parameters file. Default: infra/main.parameters.local.json (gitignored).

.PARAMETER DeploymentName
  Subscription deployment name. Default: rag-kb-bicep-<timestamp>.

.PARAMETER WhatIf
  Run a dry-run (what-if) only; do not deploy.

.PARAMETER SkipPostDeploy
  Deploy the Bicep but skip running scripts/post_deploy_search.py afterwards.

.PARAMETER Verify
  After deploying + configuring, run the post-deploy script's --verify mode for smoke tests.

.PARAMETER RestoreFoundry
  Set this switch ONLY when a prior deploy failed with `FlagMustBeSetForRestore`
  (Cognitive Services 48-hour soft-delete retention on the Foundry account name).
  Adds `restoreFoundryFromSoftDelete=true` to the Bicep parameters so the Foundry
  account is restored in place from soft-delete — preserves the system-assigned MI
  principal ID and any role assignments granted to it (notably the DI-caller SP's
  Cognitive Services User grant from 06-fabric-setup.md § F2.2).
  CAUTION: do NOT set this switch on a healthy deploy or when no soft-deleted account
  exists — Azure returns `CanNotRestoreANonExistingResource` and the deploy fails.
  See docs/05-troubleshooting.md § 0.5.

.PARAMETER TenantId
  Optional. Entra tenant ID the deployment must target. With -SubscriptionId, the script
  stops unless the active `az account show` context matches (multi-tenant guard).

.PARAMETER SubscriptionId
  Optional. Subscription ID the deployment must target (see -TenantId).

.EXAMPLE
  pwsh ./infra/deploy.ps1 -WhatIf

.EXAMPLE
  pwsh ./infra/deploy.ps1 -TenantId <tenant-id> -SubscriptionId <subscription-id> -Verify

.EXAMPLE
  pwsh ./infra/deploy.ps1 -ParameterFile infra/main.parameters.local.json -Verify

.EXAMPLE
  # Recovering from a `FlagMustBeSetForRestore` failure
  pwsh ./infra/deploy.ps1 -RestoreFoundry
#>

[CmdletBinding()]
param(
    [string]$ParameterFile = "infra/main.parameters.local.json",
    [string]$DeploymentName = "rag-kb-bicep-$(Get-Date -Format yyyyMMdd-HHmm)",
    [switch]$WhatIf,
    [switch]$SkipPostDeploy,
    [switch]$Verify,
    # Set this switch ONLY when a prior deploy failed with `FlagMustBeSetForRestore`
    # (Cognitive Services 48-hour soft-delete retention). Adds restoreFoundryFromSoftDelete=true
    # to the Bicep parameters so the Foundry account is restored in place (preserves MI
    # principal ID + role assignments). Has no effect when no soft-deleted account exists —
    # in fact will FAIL with CanNotRestoreANonExistingResource if you set it gratuitously.
    # See docs/05-troubleshooting.md § 0.5.
    [switch]$RestoreFoundry,
    # Optional tenant/subscription guard (recommended - see docs/03-deployment.md Phase 0).
    # When both are set, the script stops unless `az account show` matches them.
    [string]$TenantId,
    [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
. "$PSScriptRoot/hooks/common.ps1"   # shared with the azd hooks (ids writer, post-deploy, tenant guard)

# --- Sanity checks --------------------------------------------------------------

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI ('az') not found in PATH. Install per https://learn.microsoft.com/cli/azure/install-azure-cli"
}

if (-not (Get-Command bicep -ErrorAction SilentlyContinue) -and -not (az bicep version 2>$null)) {
    Write-Host "Bicep extension not detected — installing..." -ForegroundColor Yellow
    az bicep install | Out-Null
}

if (-not (Test-Path $ParameterFile)) {
    Write-Error @"
Parameter file not found: $ParameterFile

Copy the template and fill in your values:
    Copy-Item infra/main.parameters.json $ParameterFile
    # then edit $ParameterFile (it is gitignored)
"@
}

if ($TenantId -or $SubscriptionId) {
    Assert-AzContextMatches -TenantId $TenantId -SubscriptionId $SubscriptionId
}

# --- Resolve region from the parameter file -------------------------------------

$paramJson = Get-Content $ParameterFile -Raw | ConvertFrom-Json
$location = $paramJson.parameters.location.value
if (-not $location) {
    Write-Error "Parameter file does not contain a 'location' value."
}

Write-Host ""
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " RAG Knowledge-Base Pattern — Bicep deployment" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host (" Parameter file : {0}" -f $ParameterFile)
Write-Host (" Deployment name: {0}" -f $DeploymentName)
Write-Host (" Location       : {0}" -f $location)
Write-Host (" Subscription   : {0}" -f (az account show --query name -o tsv))
Write-Host (" Tenant         : {0}" -f (az account show --query tenantId -o tsv))
Write-Host ""

# --- What-if --------------------------------------------------------------------

if ($WhatIf) {
    Write-Host "Running what-if (dry run)..." -ForegroundColor Yellow
    $whatIfArgs = @(
        '--location', $location,
        '--template-file', 'infra/main.bicep',
        '--parameters', $ParameterFile
    )
    if ($RestoreFoundry) {
        Write-Host "  (RestoreFoundry switch is ON — adding restoreFoundryFromSoftDelete=true)" -ForegroundColor DarkGray
        $whatIfArgs += '--parameters'
        $whatIfArgs += 'restoreFoundryFromSoftDelete=true'
    }
    az deployment sub what-if @whatIfArgs
    Write-Host ""
    Write-Host "What-if complete. Re-run without -WhatIf to deploy." -ForegroundColor Green
    exit 0
}

# --- Deploy ---------------------------------------------------------------------

Write-Host "Submitting Bicep deployment..." -ForegroundColor Yellow
$deployArgs = @(
    '--name', $DeploymentName,
    '--location', $location,
    '--template-file', 'infra/main.bicep',
    '--parameters', $ParameterFile,
    '--output', 'json'
)
if ($RestoreFoundry) {
    Write-Host "  (RestoreFoundry switch is ON — adding restoreFoundryFromSoftDelete=true)" -ForegroundColor DarkGray
    $deployArgs += '--parameters'
    $deployArgs += 'restoreFoundryFromSoftDelete=true'
}
$deploy = az deployment sub create @deployArgs | ConvertFrom-Json

if (-not $deploy -or $deploy.properties.provisioningState -ne "Succeeded") {
    Write-Error "Deployment did not succeed. Run: az deployment sub show --name $DeploymentName"
}

Write-Host ""
Write-Host "Deployment succeeded." -ForegroundColor Green

# --- Merge outputs into demo-ids.local.json -------------------------------------
#
# demo-ids.local.json is a HYBRID file: the Bicep deploymentSummary owns the flat Azure
# keys (overwritten on every deploy); nested sections maintained by hand (corpus,
# fabric, sp-rag-di-caller, copilotStudio) are preserved. The writer lives in
# infra/hooks/common.ps1 and is shared with the azd postprovision hook, so both paths
# produce the same file. Reference: docs/13-configuration-reference.md section 3.

$summary = $deploy.properties.outputs.deploymentSummary.value
$idsPath = "demo-ids.local.json"
$summaryHash = [ordered]@{}
foreach ($prop in $summary.PSObject.Properties) { $summaryHash[$prop.Name] = $prop.Value }
Write-DemoIdsFile -Path $idsPath -Summary $summaryHash -DeploymentName $DeploymentName -Source 'infra/main.bicep deploymentSummary output (written by infra/deploy.ps1)'
Write-Host ""
Write-Host "Resources deployed:" -ForegroundColor Cyan
Write-Host (" Resource group  : {0}" -f $summary.resourceGroup)
Write-Host (" Key Vault       : {0}" -f $summary.keyVault)
Write-Host (" Storage         : {0} ({1}, {2})" -f $summary.storageAccount, $summary.rawContainer, $summary.chunksContainer)
Write-Host (" Foundry         : {0}" -f $summary.foundryResource)
Write-Host (" Foundry endpoint: {0}" -f $summary.foundryOpenAIEndpoint)
Write-Host ("   embedding     : {0} ({1})" -f $summary.embeddingDeployment, $summary.embeddingModel)
if ($summary.chatDeployed) {
    Write-Host ("   chat          : {0} ({1})" -f $summary.chatDeployment, $summary.chatModel)
} else {
    Write-Host "   chat          : (skipped — chatModelName param is empty; not required by the locked design)" -ForegroundColor DarkGray
}
Write-Host ("   doc intel.    : {0} (same Foundry account, multi-service)" -f $summary.documentIntelligenceEndpoint)
Write-Host (" AI Search       : {0}" -f $summary.searchService)
Write-Host (" AI Search MI ID : {0}" -f $summary.searchPrincipalId)
Write-Host ""

# --- Post-deploy script ---------------------------------------------------------

if ($SkipPostDeploy) {
    Write-Host "Skipping post-deploy (SkipPostDeploy)." -ForegroundColor Yellow
    Write-Host "When ready, run:  python scripts/post_deploy_search.py --ids $idsPath" -ForegroundColor Yellow
    exit 0
}

Write-Host "Running post-deploy AI Search configuration..." -ForegroundColor Yellow

if ((Invoke-PostDeploySearch -IdsPath $idsPath) -ne 0) {
    Write-Error "post_deploy_search.py failed. See output above; re-run after fixing (role propagation can take ~15 minutes)."
}

Write-Host ""Write-Host "Post-deploy configuration complete." -ForegroundColor Green
Write-Host ""

# --- Verify ---------------------------------------------------------------------

if ($Verify) {
    Write-Host "Running --verify smoke tests..." -ForegroundColor Yellow
    if ((Invoke-PostDeploySearch -IdsPath $idsPath -Verify) -ne 0) {
        Write-Error "Verification failed."
    }
    Write-Host ""
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " Bicep + AI Search configuration done." -ForegroundColor Cyan
Write-Host " NEXT: Manually stand up Fabric workspace + Copilot Studio agent." -ForegroundColor Cyan
Write-Host " See: docs/00-reproduce-this-demo.md Parts C and D" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

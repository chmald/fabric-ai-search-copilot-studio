# azd preprovision hook - runs before `azd provision` / `azd up` touches Azure.
# 1) validates names, 2) refuses to run against the wrong tenant/subscription,
# 3) handles soft-deleted Foundry accounts and Key Vaults that block same-name redeploys.
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/common.ps1"

$envName        = Get-EnvValue -Name "AZURE_ENV_NAME"
$location       = Get-EnvValue -Name "AZURE_LOCATION" -Default "eastus2"
$tenantId       = Get-EnvValue -Name "AZURE_TENANT_ID"
$subscriptionId = Get-EnvValue -Name "AZURE_SUBSCRIPTION_ID"
$workloadName   = Get-EnvValue -Name "WORKLOAD_NAME" -Default "rag"
$workloadEnv    = Get-EnvValue -Name "WORKLOAD_ENV" -Default "dev"

Assert-EnvName -EnvironmentName $envName
Assert-WorkloadNaming -WorkloadName $workloadName -WorkloadEnv $workloadEnv -Location $location
Assert-AllowedValue -Name "SEARCH_SKU" -Value (Get-EnvValue -Name "SEARCH_SKU" -Default "standard") -Allowed @("basic", "standard", "standard2", "standard3")
Assert-AllowedValue -Name "EMBEDDING_MODEL_SKU" -Value (Get-EnvValue -Name "EMBEDDING_MODEL_SKU" -Default "Standard") -Allowed @("Standard", "GlobalStandard", "DataZoneStandard")
Assert-AllowedValue -Name "CHAT_MODEL_SKU" -Value (Get-EnvValue -Name "CHAT_MODEL_SKU" -Default "GlobalStandard") -Allowed @("Standard", "GlobalStandard", "DataZoneStandard")
Assert-AllowedValue -Name "DEPLOY_WEB_APP" -Value (Get-EnvValue -Name "DEPLOY_WEB_APP" -Default "false") -Allowed @("true", "false")
Assert-AllowedValue -Name "CONFIGURE_SEARCH" -Value (Get-EnvValue -Name "CONFIGURE_SEARCH" -Default "true") -Allowed @("true", "false")
Assert-AllowedValue -Name "PURGE_SOFT_DELETED" -Value (Get-EnvValue -Name "PURGE_SOFT_DELETED" -Default "false") -Allowed @("true", "false")

# azd and az keep separate logins - the hooks and scripts use az (azure-cli-auth discipline).
Assert-AzContextMatches -TenantId $tenantId -SubscriptionId $subscriptionId

$names = Get-ResourceNames -WorkloadName $workloadName -WorkloadEnv $workloadEnv -Location $location
$restore = Invoke-SoftDeleteGuard -FoundryName $names.foundry -KeyVaultName $names.keyVault
$wanted = if ($restore) { "true" } else { "false" }
if ((Get-EnvValue -Name "RESTORE_FOUNDRY_FROM_SOFT_DELETE" -Default "false") -ne $wanted) {
    # true on a fresh create fails with CanNotRestoreANonExistingResource; false with a
    # soft-deleted account fails with FlagMustBeSetForRestore. Keep it in step with reality.
    Set-AzdEnvironmentValue -Name "RESTORE_FOUNDRY_FROM_SOFT_DELETE" -Value $wanted
    Write-Host "RESTORE_FOUNDRY_FROM_SOFT_DELETE set to $wanted."
}

$chat = Get-EnvValue -Name "CHAT_MODEL_NAME"
Write-Host ""
Write-Host "Preprovision checks passed for azd environment '$envName'." -ForegroundColor Green
Write-Host "  Resource group : $(if ($rg = Get-EnvValue -Name 'AZURE_RESOURCE_GROUP') { $rg } else { $names.resourceGroup })"
Write-Host "  Region         : $location"
Write-Host "  Search SKU     : $(Get-EnvValue -Name 'SEARCH_SKU' -Default 'standard')"
Write-Host "  Chat model     : $(if ($chat) { $chat } else { '(none - the default Copilot Studio path does not need one)' })"

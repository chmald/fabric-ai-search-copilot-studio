# =====================================================================================
# infra/hooks/common.ps1 — functions shared by the azd hooks AND infra/deploy.ps1
# =====================================================================================
# Dot-source it:  . "$PSScriptRoot/common.ps1"         (hooks)
#                 . "$PSScriptRoot/hooks/common.ps1"   (deploy.ps1)
# Keeping the ids-file writer, the soft-delete guard and the AI Search post-deploy call
# in one place means the azd path and the script path cannot drift.
# =====================================================================================

function Get-DemoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ""
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Set-AzdEnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    & azd env set $Name $Value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "azd env set $Name failed." }
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

function Assert-EnvName {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$EnvironmentName)
    if ($EnvironmentName -cnotmatch '^[a-z0-9][a-z0-9-]{0,19}$' -or $EnvironmentName.EndsWith("-")) {
        throw "AZURE_ENV_NAME must be lowercase alphanumeric plus hyphen, start with a letter or digit, not end with a hyphen, and be <= 20 characters. Current value: '$EnvironmentName'."
    }
}

function Assert-AllowedValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string[]]$Allowed
    )
    if ($Allowed -cnotcontains $Value) {
        throw "$Name must be one of: $($Allowed -join ', '). Current value: '$Value'."
    }
}

function Get-ResourceNames {
    # Mirrors the naming block in infra/main.bicep. Keep the two in sync.
    param(
        [Parameter(Mandatory = $true)][string]$WorkloadName,
        [Parameter(Mandatory = $true)][string]$WorkloadEnv,
        [Parameter(Mandatory = $true)][string]$Location
    )
    $locationShort = ($Location -replace '[ -]', '').ToLowerInvariant()
    $suffix = "$WorkloadName-$WorkloadEnv-$locationShort"
    $kv = "kv-$suffix"
    if ($kv.Length -gt 24) { $kv = $kv.Substring(0, 24) }
    return [ordered]@{
        resourceGroup  = "rg-$suffix"
        foundry        = "aif-$suffix"
        search         = "srch-$suffix"
        keyVault       = $kv
        storageAccount = ("st$WorkloadName$WorkloadEnv$locationShort" -replace '-', '').ToLowerInvariant()
    }
}

function Assert-WorkloadNaming {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$WorkloadName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$WorkloadEnv,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Location
    )
    if ($WorkloadName -cnotmatch '^[a-z0-9]{2,8}$') {
        throw "WORKLOAD_NAME must be 2-8 lowercase letters/digits (it is part of the storage account name). Current value: '$WorkloadName'."
    }
    Assert-AllowedValue -Name "WORKLOAD_ENV" -Value $WorkloadEnv -Allowed @("dev", "test", "prod")
    if ([string]::IsNullOrWhiteSpace($Location)) { throw "AZURE_LOCATION must be set (azd env set AZURE_LOCATION <region>)." }
    $names = Get-ResourceNames -WorkloadName $WorkloadName -WorkloadEnv $WorkloadEnv -Location $Location
    if ($names.storageAccount.Length -gt 24) {
        throw "Storage account name '$($names.storageAccount)' is $($names.storageAccount.Length) characters (max 24). Shorten WORKLOAD_NAME or pick a region with a shorter name."
    }
    if ($names.keyVault.EndsWith("-")) {
        throw "Key Vault name '$($names.keyVault)' would end with a hyphen after truncation to 24 characters. Change WORKLOAD_NAME by one character."
    }
}

function Assert-AzContextMatches {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TenantId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SubscriptionId
    )
    if ([string]::IsNullOrWhiteSpace($TenantId) -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw "AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID must both be set before provisioning: azd env set AZURE_TENANT_ID <tenant-id> ; azd env set AZURE_SUBSCRIPTION_ID <subscription-id>"
    }
    $raw = & az account show --query "{tenant:tenantId,subscription:id,user:user.name}" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw "Azure CLI is not signed in. azd and az keep separate logins; sign az in explicitly: az login --tenant $TenantId ; az account set --subscription $SubscriptionId"
    }
    $active = $raw | ConvertFrom-Json
    if ($active.tenant -ne $TenantId -or $active.subscription -ne $SubscriptionId) {
        Write-Host "Active Azure CLI context does not match this environment." -ForegroundColor Yellow
        Write-Host "  Active tenant/subscription:   $($active.tenant) / $($active.subscription)"
        Write-Host "  Expected tenant/subscription: $TenantId / $SubscriptionId"
        Write-Host "Fix with:"
        Write-Host "  az login --tenant $TenantId"
        Write-Host "  az account set --subscription $SubscriptionId"
        throw "Refusing to continue with the wrong Azure CLI tenant/subscription."
    }
}

function Invoke-SoftDeleteGuard {
    # Soft-deleted Foundry (Cognitive Services) accounts and Key Vaults block a same-name
    # redeploy. Foundry: restore in place by default (keeps the MI principal ID and every
    # grant made to it, e.g. the DI-caller SP in docs/06 F2.2). Key Vault: recover by
    # default. PURGE_SOFT_DELETED=true purges both instead (destructive, irreversible).
    # Returns $true when the Foundry account must be restored (restoreFoundryFromSoftDelete).
    param(
        [Parameter(Mandatory = $true)][string]$FoundryName,
        [Parameter(Mandatory = $true)][string]$KeyVaultName
    )
    $purge = (Get-EnvValue -Name "PURGE_SOFT_DELETED" -Default "false") -eq "true"
    $restoreFoundry = $false

    $deletedAccounts = & az cognitiveservices account list-deleted -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($deletedAccounts)) {
        $match = @($deletedAccounts | ConvertFrom-Json) | Where-Object { $_.name -eq $FoundryName } | Select-Object -First 1
        if ($match) {
            if ($purge) {
                $rg = ($match.id -split '/resourceGroups/')[1].Split('/')[0]
                Write-Host "PURGE_SOFT_DELETED=true: purging soft-deleted Foundry account '$FoundryName'..." -ForegroundColor Yellow
                & az cognitiveservices account purge --name $FoundryName --resource-group $rg --location $match.location --only-show-errors | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Purging soft-deleted Foundry account '$FoundryName' failed." }
            }
            else {
                Write-Host "Soft-deleted Foundry account '$FoundryName' found - it will be restored in place." -ForegroundColor Cyan
                $restoreFoundry = $true
            }
        }
    }
    $global:LASTEXITCODE = 0

    $deletedVaults = & az keyvault list-deleted --resource-type vault -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($deletedVaults)) {
        $vault = @($deletedVaults | ConvertFrom-Json) | Where-Object { $_.name -eq $KeyVaultName } | Select-Object -First 1
        if ($vault) {
            if ($purge) {
                Write-Host "PURGE_SOFT_DELETED=true: purging soft-deleted Key Vault '$KeyVaultName'..." -ForegroundColor Yellow
                & az keyvault purge --name $KeyVaultName --only-show-errors | Out-Null
            }
            else {
                Write-Host "Soft-deleted Key Vault '$KeyVaultName' found - recovering it so the deployment can update it." -ForegroundColor Cyan
                & az keyvault recover --name $KeyVaultName --only-show-errors | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { throw "Handling soft-deleted Key Vault '$KeyVaultName' failed. Purge protection blocks purge; recover it, or change WORKLOAD_NAME." }
        }
    }
    $global:LASTEXITCODE = 0
    return $restoreFoundry
}

function ConvertTo-Bool {
    param([AllowEmptyString()][string]$Value)
    return ($Value -eq "true" -or $Value -eq "True")
}

function Get-SummaryFromAzdEnv {
    # Rebuilds the main.bicep deploymentSummary object from the azd outputs/env so both
    # paths write an identical demo-ids.local.json.
    return [ordered]@{
        subscriptionId               = Get-EnvValue -Name "AZURE_SUBSCRIPTION_ID"
        tenantId                     = Get-EnvValue -Name "AZURE_TENANT_ID"
        resourceGroup                = Get-EnvValue -Name "AZURE_RESOURCE_GROUP"
        region                       = Get-EnvValue -Name "AZURE_LOCATION"
        environment                  = Get-EnvValue -Name "WORKLOAD_ENV" -Default "dev"
        workload                     = Get-EnvValue -Name "WORKLOAD_NAME" -Default "rag"
        storageAccount               = Get-EnvValue -Name "STORAGE_ACCOUNT_NAME"
        blobEndpoint                 = Get-EnvValue -Name "BLOB_ENDPOINT"
        rawContainer                 = Get-EnvValue -Name "RAW_CONTAINER" -Default "raw"
        chunksContainer              = Get-EnvValue -Name "CHUNKS_CONTAINER" -Default "chunks"
        keyVault                     = Get-EnvValue -Name "KEY_VAULT_NAME"
        keyVaultUri                  = Get-EnvValue -Name "KEY_VAULT_URI"
        foundryResource              = Get-EnvValue -Name "FOUNDRY_RESOURCE_NAME"
        foundryOpenAIEndpoint        = Get-EnvValue -Name "FOUNDRY_OPENAI_ENDPOINT"
        documentIntelligenceEndpoint = Get-EnvValue -Name "DOCUMENT_INTELLIGENCE_ENDPOINT"
        embeddingDeployment          = Get-EnvValue -Name "EMBEDDING_DEPLOYMENT" -Default "embedding"
        embeddingModel               = Get-EnvValue -Name "EMBEDDING_MODEL_NAME" -Default "text-embedding-3-large"
        chatDeployment               = Get-EnvValue -Name "CHAT_DEPLOYMENT"
        chatModel                    = Get-EnvValue -Name "CHAT_MODEL_NAME"
        chatDeployed                 = ConvertTo-Bool (Get-EnvValue -Name "CHAT_DEPLOYED")
        searchService                = Get-EnvValue -Name "SEARCH_SERVICE_NAME"
        searchEndpoint               = Get-EnvValue -Name "SEARCH_ENDPOINT"
        searchPrincipalId            = Get-EnvValue -Name "SEARCH_PRINCIPAL_ID"
        searchIndexName              = Get-EnvValue -Name "SEARCH_INDEX_NAME" -Default "idx-rag-documents"
        searchDataSourceName         = Get-EnvValue -Name "SEARCH_DATA_SOURCE_NAME" -Default "ds-chunks"
        searchIndexerName            = Get-EnvValue -Name "SEARCH_INDEXER_NAME" -Default "ixr-chunks"
        authMode                     = "entra-only"
        localAuthDisabled            = $true
        deployerHasSearchRoles       = ConvertTo-Bool (Get-EnvValue -Name "DEPLOYER_HAS_SEARCH_ROLES")
        webAppDeployed               = ConvertTo-Bool (Get-EnvValue -Name "WEBAPP_DEPLOYED")
        webAppAcr                    = Get-EnvValue -Name "WEBAPP_ACR_NAME"
        webAppAcrLoginServer         = Get-EnvValue -Name "WEBAPP_ACR_LOGIN_SERVER"
        webAppEnvironment            = Get-EnvValue -Name "WEBAPP_ENVIRONMENT_NAME"
        webAppIdentityName           = Get-EnvValue -Name "WEBAPP_IDENTITY_NAME"
        webAppIdentityClientId       = Get-EnvValue -Name "WEBAPP_IDENTITY_CLIENT_ID"
        webAppIdentityResourceId     = Get-EnvValue -Name "WEBAPP_IDENTITY_RESOURCE_ID"
    }
}

function Write-DemoIdsFile {
    # demo-ids.local.json is HYBRID: the deployment summary owns the flat Azure keys
    # (overwritten on every deploy); nested sections added by humans (corpus, fabric,
    # sp-rag-di-caller, copilotStudio) are preserved. On first write the corpus block is
    # seeded from demo-ids.template.json.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Summary,
        [Parameter(Mandatory = $true)][string]$DeploymentName,
        [Parameter(Mandatory = $true)][string]$Source
    )
    $existing = [ordered]@{}
    if (Test-Path $Path) {
        try { $existing = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20 }
        catch { Write-Warning "Existing $Path could not be parsed as JSON; it will be replaced (manual sections will be lost)."; $existing = [ordered]@{} }
    }
    if (-not $existing.Contains('corpus')) {
        $templatePath = Join-Path (Get-DemoRoot) "demo-ids.template.json"
        if (Test-Path $templatePath) {
            $template = Get-Content $templatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 20
            if ($template.Contains('corpus')) { $existing['corpus'] = $template['corpus'] }
        }
    }

    $merged = [ordered]@{}
    $merged['_meta'] = [ordered]@{
        description        = 'Per-deployment IDs for this pattern. Top-level Azure fields are written from the main.bicep deploymentSummary (by infra/deploy.ps1 or the azd postprovision hook) and overwritten on every successful deploy. Nested objects (corpus, fabric, sp-rag-di-caller, copilotStudio) are maintained by hand and preserved across deploys. This file is gitignored - never commit a populated copy.'
        azureFieldsSource  = $Source
        manualSections     = @('corpus', 'fabric', 'sp-rag-di-caller', 'copilotStudio')
        lastDeployedAt     = (Get-Date -Format 'o')
        lastDeploymentName = $DeploymentName
    }
    foreach ($key in ($Summary.Keys | Sort-Object)) { $merged[$key] = $Summary[$key] }
    foreach ($key in $existing.Keys) {
        if ($key -eq '_meta') { continue }
        if (-not $Summary.Contains($key)) { $merged[$key] = $existing[$key] }
    }
    $merged | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
    $preserved = @($merged.Keys | Where-Object { $_ -ne '_meta' -and -not $Summary.Contains($_) })
    $suffix = if ($preserved.Count) { " (preserved: $($preserved -join ', '))" } else { "" }
    Write-Host "Outputs merged into $Path$suffix" -ForegroundColor Green
}

function Get-PythonCommand {
    foreach ($candidate in @("python", "python3", "py")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -notmatch 'WindowsApps') { return $cmd.Source }
    }
    return $null
}

function Invoke-PostDeploySearch {
    # Runs scripts/post_deploy_search.py (index + data source + skillset + indexer).
    # Returns the script's exit code; never throws, so callers decide how hard to fail.
    param(
        [Parameter(Mandatory = $true)][string]$IdsPath,
        [switch]$Verify
    )
    $root = Get-DemoRoot
    $python = Get-PythonCommand
    if (-not $python) {
        Write-Host "Python 3.11+ was not found on PATH; skipping the AI Search configuration. Run it later: python scripts/post_deploy_search.py --ids $IdsPath" -ForegroundColor Yellow
        return 1
    }
    $marker = Join-Path $root "scripts/.deps-installed"
    if (-not (Test-Path $marker)) {
        Write-Host "Installing scripts/requirements.txt..." -ForegroundColor Yellow
        & $python -m pip install -r (Join-Path $root "scripts/requirements.txt") --quiet | Out-Host
        if ($LASTEXITCODE -ne 0) { Write-Host "pip install failed." -ForegroundColor Yellow; return $LASTEXITCODE }
        New-Item -Path $marker -ItemType File -Force | Out-Null
    }
    $scriptArgs = @((Join-Path $root "scripts/post_deploy_search.py"), "--ids", $IdsPath)
    if ($Verify) { $scriptArgs += "--verify" }
    & $python @scriptArgs | Out-Host
    return $LASTEXITCODE
}

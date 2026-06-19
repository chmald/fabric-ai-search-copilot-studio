<#
.SYNOPSIS
    Deploy the Microsoft Foundry agent web app (upstream sample) as a standalone
    front end for this pattern's Foundry agent, in On-Behalf-Of (OBO) mode.

.DESCRIPTION
    Thin wrapper over the Azure Developer CLI (azd). Reads webapp/.env, applies
    the agent identifiers and the OBO flag via `azd env set`, then runs `azd up`.

    This script does NOT contain application code. The web app itself comes from
    `azd init -t microsoft-foundry/foundry-agent-webapp` (run once before this).
    See docs/09-foundry-agent-webapp.md for the full runbook.

.PARAMETER EnvFile
    Path to the env file (default: webapp/.env next to this script).

.PARAMETER WhatIf
    Print the azd commands without running azd up.

.EXAMPLE
    pwsh ./webapp/deploy-webapp.ps1

.EXAMPLE
    pwsh ./webapp/deploy-webapp.ps1 -WhatIf
#>
[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

# --- Preconditions ----------------------------------------------------------
if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
    throw "Azure Developer CLI (azd) not found. Install it: https://aka.ms/install-azd"
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "Env file not found: $EnvFile`nCopy webapp/.env.example to webapp/.env and fill it in."
}

if (-not (Test-Path -LiteralPath (Join-Path (Get-Location) 'azure.yaml'))) {
    Write-Warning "No azure.yaml in the current directory. Run 'azd init -t microsoft-foundry/foundry-agent-webapp' first (see docs/09 W2), then re-run this script from the app root."
}

# --- Parse the env file -----------------------------------------------------
$envVars = @{}
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
    $kv = $trimmed.Split('=', 2)
    if ($kv.Count -ne 2) { continue }
    $key = $kv[0].Trim()
    $val = $kv[1].Trim().Trim('"').Trim("'")
    if (-not [string]::IsNullOrWhiteSpace($val)) { $envVars[$key] = $val }
}

# Required keys
$required = @('AZURE_EXISTING_AGENT_ID', 'AZURE_EXISTING_AIPROJECT_ENDPOINT', 'AZURE_EXISTING_RESOURCE_ID')
$missing = $required | Where-Object { -not $envVars.ContainsKey($_) }
if ($missing) {
    throw "Missing required values in ${EnvFile}: $($missing -join ', ')"
}

# Reject unedited placeholder values (anything still containing a <...> token)
$placeholder = $envVars.Keys | Where-Object { $envVars[$_] -match '<[^>]+>' }
if ($placeholder) {
    throw "Unedited placeholder values in ${EnvFile}: $($placeholder -join ', '). Replace the <...> tokens with real values before deploying."
}

# --- OBO guard --------------------------------------------------------------
$oboKeys = @('ENABLE_OBO', 'enableObo')
$oboOn = $false
foreach ($k in $oboKeys) {
    if ($envVars.ContainsKey($k) -and $envVars[$k] -ieq 'true') { $oboOn = $true }
}
if (-not $oboOn) {
    Write-Warning "OBO is not enabled. The Microsoft Fabric data agent tool requires OBO (user identity passthrough). Set ENABLE_OBO=true in $EnvFile unless your agent is AI-Search-only. See docs/09."
}

# --- Apply env + deploy -----------------------------------------------------
Write-Host "Applying configuration via azd env set..." -ForegroundColor Cyan
foreach ($key in $envVars.Keys) {
    Write-Host "  azd env set $key <value>"
    if (-not $WhatIf) { azd env set $key $envVars[$key] | Out-Null }
}

if ($WhatIf) {
    Write-Host "`n-WhatIf: skipping 'azd up'." -ForegroundColor Yellow
    return
}

Write-Host "`nRunning 'azd up'..." -ForegroundColor Cyan
azd up

Write-Host "`nDone. Validate per docs/09 W5 (document + structured questions, two-user RLS check)." -ForegroundColor Green

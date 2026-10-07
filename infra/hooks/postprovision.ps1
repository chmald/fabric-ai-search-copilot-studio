# azd postprovision hook - runs after `azd provision` / `azd up` created the resources.
# 1) writes demo-ids.local.json from the azd outputs (same writer as infra/deploy.ps1),
# 2) configures the AI Search index / data source / skillset / indexer (CONFIGURE_SEARCH),
# 3) prints the manual next steps (Fabric, agent, optional web app).
$ErrorActionPreference = "Stop"
. "$PSScriptRoot/common.ps1"

$root = Get-DemoRoot
$idsPath = Join-Path $root "demo-ids.local.json"
$envName = Get-EnvValue -Name "AZURE_ENV_NAME"
Write-DemoIdsFile -Path $idsPath -Summary (Get-SummaryFromAzdEnv) -DeploymentName "main-$envName" -Source "infra/azd.bicep outputs (written by infra/hooks/postprovision.ps1)"

if ((Get-EnvValue -Name "CONFIGURE_SEARCH" -Default "true") -eq "true") {
    Write-Host ""
    Write-Host "Configuring AI Search (index, data source, skillset, indexer)..." -ForegroundColor Yellow
    $code = Invoke-PostDeploySearch -IdsPath $idsPath
    if ($code -ne 0) {
        # The platform is provisioned; only the idempotent data-plane step failed. The usual
        # cause on a first run is role propagation (up to ~15 minutes for the new search roles).
        Write-Host ""
        Write-Host "AI Search configuration did not complete (exit $code). The Azure resources are deployed." -ForegroundColor Yellow
        Write-Host "  Most common cause: the new Search Service Contributor / Search Index Data Contributor" -ForegroundColor Yellow
        Write-Host "  assignments are still propagating. Wait a few minutes, then re-run either:" -ForegroundColor Yellow
        Write-Host "    azd hooks run postprovision" -ForegroundColor Yellow
        Write-Host "    python scripts/post_deploy_search.py --ids demo-ids.local.json" -ForegroundColor Yellow
        Write-Host "  Diagnosis: docs/05-troubleshooting.md (azd triage + section 4)." -ForegroundColor Yellow
    }
}
else {
    Write-Host "CONFIGURE_SEARCH=false - skipped the AI Search configuration. Run it later: python scripts/post_deploy_search.py --ids demo-ids.local.json" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Azure platform layer is ready. Next (manual, no ARM surface):" -ForegroundColor Cyan
Write-Host "  1. Fabric workspace, Lakehouse and ingest pipeline  -> docs/06-fabric-setup.md"
Write-Host "  2. Agent: Copilot Studio (default)                   -> docs/07-copilot-studio-setup.md"
Write-Host "     or Foundry Agent Service (alternative)            -> docs/08-foundry-agent-setup.md"
if ((Get-EnvValue -Name "WEBAPP_DEPLOYED" -Default "false") -eq "true") {
    Write-Host "  3. Web app image (platform provisioned)              -> pwsh ./scripts/deploy-webapp.ps1  (docs/12)"
}
Write-Host "  Verify any time: python scripts/post_deploy_search.py --ids demo-ids.local.json --verify"

#requires -Version 7.0
<#
.SYNOPSIS
Mirror the current HEAD of this repo to a public GitHub repo as a single fresh commit.

.DESCRIPTION
The published snapshot has no git history and force-overrides whatever is on the target.
Only tracked files reach the snapshot (uses `git archive HEAD`) — gitignored files like
`demo-ids.local.json` are structurally excluded.

This script itself and `.gitattributes` are marked `export-ignore` so they do NOT ship
to the public mirror.

.PARAMETER TargetRepo
GitHub `org/repo`. Defaults to `chmald/fabric-ai-search-copilot-studio`.

.PARAMETER Branch
Branch to push on the target. Defaults to `main`.

.PARAMETER Message
Commit message for the single snapshot commit. Defaults to a date-stamped string.

.PARAMETER Yes
Skip the interactive confirmation prompt before force-pushing.

.EXAMPLE
./scripts/publish-to-github.ps1

.EXAMPLE
./scripts/publish-to-github.ps1 -Yes
#>
[CmdletBinding()]
param(
    [string]$TargetRepo = 'chmald/fabric-ai-search-copilot-studio',
    [string]$Branch     = 'main',
    [string]$Message    = "Snapshot from internal source ($(Get-Date -Format 'yyyy-MM-dd'))",
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# Always run from the repo root, regardless of where the caller invoked us
$repoRoot = git -C $PSScriptRoot rev-parse --show-toplevel
if (-not $repoRoot) { throw 'Could not locate the repo root from this script location.' }
Set-Location $repoRoot

# Sanity: working tree must be clean so HEAD reflects what we publish
$dirty = git status --porcelain
if ($dirty) {
    Write-Warning "Working tree is not clean. The mirror publishes HEAD, so uncommitted changes will NOT ship:"
    $dirty | ForEach-Object { Write-Host "  $_" }
    if (-not $Yes) {
        $ans = Read-Host "Continue anyway? (y/N)"
        if ($ans -notmatch '^[Yy]') { Write-Host 'Aborted.'; return }
    }
}

$shortSha = (git rev-parse --short HEAD).Trim()
$staging  = Join-Path $env:TEMP "pub-$([guid]::NewGuid().ToString('N').Substring(0,8))"

Write-Host ""
Write-Host "Source HEAD : $shortSha"
Write-Host "Target repo : https://github.com/$TargetRepo (branch: $Branch)"
Write-Host "Staging dir : $staging"
Write-Host ""

if (-not $Yes) {
    Write-Host "This will FORCE-PUSH a single-commit snapshot and overwrite whatever is on '$Branch'." -ForegroundColor Yellow
    $ans = Read-Host "Proceed? (y/N)"
    if ($ans -notmatch '^[Yy]') { Write-Host 'Aborted.'; return }
}

try {
    # 1. Export tracked files only. `export-ignore` attributes drop this script + .gitattributes.
    New-Item -ItemType Directory -Path $staging | Out-Null
    git archive --format=tar HEAD | tar -x -C $staging
    if ($LASTEXITCODE -ne 0) { throw "git archive failed (exit $LASTEXITCODE)" }

    # 2. Belt-and-suspenders: hard-fail if any *.local.json or backup file slipped in
    $leaks = Get-ChildItem -Path $staging -Recurse -File -Force |
             Where-Object { $_.Name -match '\.local\.json$|-bk\.|\.bak$|\.env$|\.pem$|\.pfx$|\.p12$|^secrets\.json$' }
    if ($leaks) {
        Write-Error "Refusing to publish — sensitive file(s) found in staging:"
        $leaks | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Red }
        throw 'Sensitive files in staging'
    }

    # 3. Fresh single-commit history
    Push-Location $staging
    try {
        git init -b $Branch | Out-Null
        git add -A
        git -c user.name="$(git -C $repoRoot config user.name)" `
            -c user.email="$(git -C $repoRoot config user.email)" `
            commit -m $Message -m "Source: internal @ $shortSha" | Out-Null

        # 4. Force-push, overriding the target
        git remote add origin "https://github.com/$TargetRepo.git"
        git push --force --set-upstream origin $Branch
        if ($LASTEXITCODE -ne 0) { throw "git push failed (exit $LASTEXITCODE)" }
    }
    finally { Pop-Location }

    Write-Host ""
    Write-Host "Published $shortSha -> https://github.com/$TargetRepo (branch: $Branch)" -ForegroundColor Green
}
finally {
    if (Test-Path $staging) {
        Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
    }
}

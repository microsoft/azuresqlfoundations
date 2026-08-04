<#
.SYNOPSIS
  Phase 0 — verify prerequisites and set up the DMS CLI path: confirm the Azure
  CLI is installed and signed in, install/update the `az datamigration` extension,
  and register the required resource providers.

.DESCRIPTION
  Run once per machine / subscription before the other dms\*.ps1 scripts.
  Idempotent — safe to re-run.

  HARD prerequisites (this script fails if missing — it cannot install them for you):
    - Azure CLI (`az`) installed and on PATH  -> https://aka.ms/installazurecli
      The `datamigration` extension needs Azure CLI core >= 2.75.0. If your CLI is
      older, this script runs `az upgrade` for you (pass -SkipAzUpgrade to opt out).

  This script DOES install/update for you:
    - the Azure CLI itself, via `az upgrade`, when it is below the required minimum
    - the `datamigration` CLI extension (no subscription / no `az login` needed)

  If you pass -SubscriptionId, it ALSO (requires `az login`):
    - confirms you're signed in and selects the subscription
    - registers the Microsoft.DataMigration and Microsoft.Sql providers
  Omit -SubscriptionId to just install the extension; providers must be registered
  before Phase 2/3 (provisioning / DMS create).

  SOFT prerequisites (reported only — needed later, not here):
    - sqlcmd / SSMS for the T-SQL steps (assess broker check, validation)
    - the Integration Runtime MSI on this machine (Phase 4 / 04-register-shir -IrPath)
      -> https://aka.ms/sql-migration-shir-download

.EXAMPLE
  .\00-setup.ps1                                  # just install the CLI extension

.EXAMPLE
  .\00-setup.ps1 -SubscriptionId <your-subscription-id>   # extension + register providers
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [switch]$SkipAzUpgrade
)

$ErrorActionPreference = 'Stop'

# Tee all console output to a timestamped log file (read it instead of the terminal).
. (Join-Path $PSScriptRoot '_log.ps1')
Start-PhaseLog '00-setup'
trap { Stop-PhaseLog; break }

$MinAzVersion = [version]'2.75.0'   # az datamigration commands require CLI core >= this
$summary = [ordered]@{}

# --- HARD: Azure CLI present (self-heals PATH after a fresh install) ---------
Write-Host "==> Checking Azure CLI is installed" -ForegroundColor Cyan
. (Join-Path $PSScriptRoot '_resolve-az.ps1')
$azVer = (az version --query '\"azure-cli\"' -o tsv 2>$null)

# --- Ensure the CLI meets the minimum the datamigration extension needs ------
$azVerParsed = $null
[version]::TryParse($azVer, [ref]$azVerParsed) | Out-Null
if ($azVerParsed -and $azVerParsed -lt $MinAzVersion) {
    if ($SkipAzUpgrade) {
        Write-Host ("==> Azure CLI v{0} is below the required v{1}, but -SkipAzUpgrade was set" -f $azVer, $MinAzVersion) -ForegroundColor Yellow
        throw "Azure CLI v$azVer is too old for the datamigration extension (need >= $MinAzVersion). Run 'az upgrade' (or re-run without -SkipAzUpgrade)."
    }
    Write-Host ("==> Azure CLI v{0} is below required v{1} — running 'az upgrade'" -f $azVer, $MinAzVersion) -ForegroundColor Yellow
    az upgrade --yes
    if ($LASTEXITCODE -ne 0) { throw "'az upgrade' failed (exit $LASTEXITCODE). Upgrade the Azure CLI manually: https://aka.ms/installazurecli" }

    # Re-check IN THIS SESSION. On Windows `az upgrade` launches the MSI installer in a
    # separate window and returns before it finishes; the new version only takes effect
    # in a NEW shell. If we still see the old version, stop cleanly and ask the user to
    # finish the installer and re-run in a fresh terminal (do not hard-fail).
    $azVer = (az version --query '\"azure-cli\"' -o tsv 2>$null)
    $azVerParsed = $null
    [version]::TryParse($azVer, [ref]$azVerParsed) | Out-Null
    if (-not $azVerParsed -or $azVerParsed -lt $MinAzVersion) {
        Write-Host ""
        Write-Host "==> The Azure CLI upgrade is finishing in a separate installer window." -ForegroundColor Yellow
        Write-Host "    1) Complete that installer if it is still open." -ForegroundColor Yellow
        Write-Host "    2) Open a NEW terminal (so the updated 'az' is on PATH)." -ForegroundColor Yellow
        Write-Host "    3) Re-run this script: .\00-setup.ps1$(if ($SubscriptionId) { " -SubscriptionId $SubscriptionId" })" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Azure CLI upgrade in progress — re-run in a fresh terminal to continue." -ForegroundColor Cyan
        return
    }
}
$summary['Azure CLI'] = if ($azVer) { "installed (v$azVer)" } else { 'installed' }

# --- Install/update the datamigration extension (no subscription needed) -----
Write-Host "==> Ensuring the 'datamigration' CLI extension is installed/updated" -ForegroundColor Cyan
$installed = az extension list --query "[?name=='datamigration'] | length(@)" -o tsv
if ($installed -eq '0') {
    az extension add --name datamigration
} else {
    az extension update --name datamigration
}
if ($LASTEXITCODE -ne 0) { throw "Installing/updating the datamigration extension failed (exit $LASTEXITCODE)." }
$extVer = (az extension show --name datamigration --query version -o tsv 2>$null)
$summary['datamigration extension'] = if ($extVer) { "v$extVer" } else { 'installed' }

# --- Ask for the subscription if it wasn't supplied -------------------------
if (-not $SubscriptionId) {
    Write-Host ""
    Write-Host "A subscription is needed to register the Microsoft.DataMigration / Microsoft.Sql providers." -ForegroundColor Cyan
    $entered = Read-Host "Enter your Azure subscription ID (or press Enter to skip and just install the extension)"
    if ($entered) { $SubscriptionId = $entered.Trim() }
}

# --- Subscription-scoped steps (only when a subscription is available) -------
if ($SubscriptionId) {
    # HARD: signed in
    Write-Host "==> Checking you are signed in (az login)" -ForegroundColor Cyan
    az account show -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Not signed in. Run 'az login' (or 'az login --use-device-code') and re-run, or omit -SubscriptionId to just install the extension."
    }
    $summary['Azure sign-in'] = 'signed in'

    Write-Host "==> Selecting subscription $SubscriptionId" -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) { throw "az account set failed (exit $LASTEXITCODE) — check the subscription ID and your access." }
    $summary['Subscription'] = $SubscriptionId

    Write-Host "==> Registering resource providers (Microsoft.DataMigration, Microsoft.Sql)" -ForegroundColor Cyan
    az provider register --namespace Microsoft.DataMigration
    if ($LASTEXITCODE -ne 0) { throw "Registering Microsoft.DataMigration failed (exit $LASTEXITCODE)." }
    az provider register --namespace Microsoft.Sql
    if ($LASTEXITCODE -ne 0) { throw "Registering Microsoft.Sql failed (exit $LASTEXITCODE)." }
    $summary['Microsoft.DataMigration'] = az provider show --namespace Microsoft.DataMigration --query "registrationState" -o tsv
    $summary['Microsoft.Sql']           = az provider show --namespace Microsoft.Sql --query "registrationState" -o tsv
}
else {
    Write-Host "==> No subscription provided: skipping sign-in and provider registration" -ForegroundColor Yellow
    $summary['Provider registration'] = 'SKIPPED — re-run and supply a subscription before Phase C/D'
}

# --- SOFT: report tools needed in later phases ------------------------------
$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
$summary['sqlcmd (T-SQL steps)'] = if ($sqlcmd) { "found ($($sqlcmd.Source))" } else { 'NOT found — install for assess/validate SQL (or use SSMS)' }
$summary['Integration Runtime MSI'] = 'installed later on the source VM (Phase D) — https://aka.ms/sql-migration-shir-download'

# --- Summary ----------------------------------------------------------------
Write-Host ""
Write-Host "Prerequisite summary:" -ForegroundColor Cyan
foreach ($k in $summary.Keys) {
    $v = $summary[$k]
    $color = if ($v -match 'NOT found|not registered|SKIPPED') { 'Yellow' } else { 'Gray' }
    Write-Host ("  {0,-26} {1}" -f $k, $v) -ForegroundColor $color
}
if ($SubscriptionId -and ($summary['Microsoft.DataMigration'] -ne 'Registered' -or $summary['Microsoft.Sql'] -ne 'Registered')) {
    Write-Host "  (provider registration can take a few minutes to reach 'Registered' — re-run to refresh)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup complete. Next: 01-assess.ps1" -ForegroundColor Green
Stop-PhaseLog

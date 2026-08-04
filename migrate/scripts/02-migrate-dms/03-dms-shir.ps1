<#
.SYNOPSIS
  Phase 3 — create the Database Migration Service (SQL Migration Service) and
  register the Self-Hosted Integration Runtime (SHIR) on this machine.

.DESCRIPTION
  DMS -> Azure SQL Database moves data via ADF pipelines driven by a SHIR, so a
  SHIR is always required (even Azure-to-Azure). This exercise runs the SHIR on the
  same box as the source, so the source connection stays on localhost.

  The script creates the DMS, retrieves its auth key, then registers the SHIR with
  that key automatically (no copy/paste). If the Integration Runtime MSI is not yet
  installed, pass -IrPath to install it first; if installed but not detected, pass
  -InstalledIrPath to the version folder.

.EXAMPLE
  .\03-dms-shir.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -Location <region> -DmsName <dms-name>

.EXAMPLE
  .\03-dms-shir.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -Location <region> -DmsName <dms-name> `
      -IrPath '<path-to>\IntegrationRuntime.msi'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$Location,
    [Parameter(Mandatory)] [string]$DmsName,

    # Optional: path to the Integration Runtime MSI to install before registering.
    # Download: https://aka.ms/sql-migration-shir-download
    [string]$IrPath = '',

    # Optional: existing IR version folder, e.g.
    # 'C:\Program Files\Microsoft Integration Runtime\5.0'
    [string]$InstalledIrPath = ''
)

$ErrorActionPreference = 'Stop'

# Tee all console output to a timestamped log file (read it instead of the terminal).
. (Join-Path $PSScriptRoot '_log.ps1')
Start-PhaseLog '03-dms-shir'
trap { Stop-PhaseLog; break }

# Ensure the Azure CLI is on PATH even right after a fresh install/upgrade.
. (Join-Path $PSScriptRoot '_resolve-az.ps1')

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "az account set failed (exit $LASTEXITCODE)." }

Write-Host "==> Creating Database Migration Service '$DmsName' in $ResourceGroup/$Location" -ForegroundColor Cyan
az datamigration sql-service create `
    --resource-group $ResourceGroup `
    --name $DmsName `
    --location $Location
if ($LASTEXITCODE -ne 0) { throw "sql-service create failed (exit $LASTEXITCODE)." }

Write-Host "==> Retrieving a SHIR authentication key" -ForegroundColor Cyan
$authKey = az datamigration sql-service list-auth-key `
    --resource-group $ResourceGroup `
    --name $DmsName `
    --query "authKey1" -o tsv
if ($LASTEXITCODE -ne 0) { throw "list-auth-key failed (exit $LASTEXITCODE)." }

$argsList = @('datamigration', 'register-integration-runtime', '--auth-key', $authKey)
if ($IrPath)          { $argsList += @('--ir-path', $IrPath) }
if ($InstalledIrPath) { $argsList += @('--installed-ir-path', $InstalledIrPath) }

Write-Host "==> Registering the Integration Runtime (SHIR) with '$DmsName'" -ForegroundColor Cyan
az @argsList
if ($LASTEXITCODE -ne 0) { throw "register-integration-runtime failed (exit $LASTEXITCODE)." }

Write-Host ""
Write-Host "DMS '$DmsName' created and SHIR registered." -ForegroundColor Green
Write-Host "Next: .\04-migrate.ps1" -ForegroundColor Green
Stop-PhaseLog

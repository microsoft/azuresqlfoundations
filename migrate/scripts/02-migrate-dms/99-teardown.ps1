<#
.SYNOPSIS
  Teardown — delete the Azure resources created by this migration so the runbook
  can be run again from a clean slate. Idempotent and safe to re-run.

.DESCRIPTION
  Removes, in dependency order, the resources created by the provisioning + DMS
  phases of this runbook:

    1. The target Hyperscale database  (drops the attached migration resource too)
    2. The Database Migration Service (DMS)
    3. The logical SQL server          (unless -KeepServer)

  Each delete is guarded by an existence check, so the script is idempotent —
  re-running after a partial teardown just skips what's already gone.

  Control-plane (ARM) calls — needs `az login`. No identity defaults are baked in;
  pass the same values you used to provision. Destructive: you must confirm (type
  `delete`) unless you pass -Force.

  -DeleteResourceGroup removes the ENTIRE resource group and everything in it.
  Use only when the group was created solely for this migration.

  -ResetTargetSchema is a lighter, data-plane reset for re-running Phase 4 only:
  it empties the target DB in place (drops all schema + data and the prior
  migration resource) but KEEPS the database, logical server, and DMS. Because
  the Hyperscale DB is not dropped, the create-time-only zone-redundancy setting
  is preserved. Requires -TargetSqlUser; confirm by typing `reset` unless -Force.

.EXAMPLE
  # Drop the DB, DMS, and logical server (full clean slate for a repeat run):
  .\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
      -ServerName <server> -DatabaseName <db> -DmsName <dms-name>

.EXAMPLE
  # Keep the logical server, only drop the migrated DB and the DMS:
  .\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
      -ServerName <server> -DatabaseName <db> -DmsName <dms-name> -KeepServer

.EXAMPLE
  # Reset for a Phase 4 re-run WITHOUT dropping the target database: empties the DB
  # in place (drops all schema + data and the prior migration resource) and keeps the
  # database, logical server, and DMS/SHIR. Preserves the create-time-only Hyperscale
  # zone-redundancy setting. Afterward, re-run Phase 4 directly (skip Phase 2).
  .\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> `
      -ServerName <server> -DatabaseName <db> -TargetSqlUser <login> -ResetTargetSchema

.EXAMPLE
  # Nuke the whole resource group (only if it holds nothing else), no prompt:
  .\99-teardown.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DeleteResourceGroup -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroup,

    # Resources to remove (supply the ones you provisioned).
    [string]$ServerName = '',                            # logical SQL server
    [string]$DatabaseName = '',                          # target Hyperscale DB
    [string]$DmsName = '',                               # Database Migration Service

    [switch]$KeepServer,                                 # drop the DB but leave the server
    [switch]$KeepDms,                                    # leave the DMS in place
    [switch]$DeleteResourceGroup,                        # delete the ENTIRE resource group
    [switch]$Force,                                      # skip the confirmation prompt

    # --- Phase 4 re-run reset (data-plane; keeps the DB, server, and DMS) ---
    # Empty the target DB in place instead of dropping it: drops every user object
    # (schema + data) and the prior migration resource so Phase 4 can run again.
    [switch]$ResetTargetSchema,
    [string]$TargetSqlUser = '',                         # SQL login on the target DB (for the in-place drop)
    [string]$ResetSchemaScript = (Join-Path $PSScriptRoot 'reset-target-schema.sql')
)

$ErrorActionPreference = 'Stop'

# Tee all console output to a timestamped log file (read it instead of the terminal).
. (Join-Path $PSScriptRoot '_log.ps1')
Start-PhaseLog '99-teardown'
trap { Stop-PhaseLog; break }

# Ensure the Azure CLI is on PATH even right after a fresh install/upgrade.
. (Join-Path $PSScriptRoot '_resolve-az.ps1')

# Control-plane (ARM) calls — require an authenticated az context.
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "az account set failed (exit $LASTEXITCODE) — run 'az login' first." }

# --- Reset target schema in place (Phase 4 re-run; keeps DB, server, DMS) ----
# Empties the target DB without dropping it: removes the prior migration resource
# (control-plane) and drops ALL user objects + data (data-plane). Preserves the
# create-time-only Hyperscale zone-redundancy setting, so re-run Phase 4 directly.
if ($ResetTargetSchema) {
    if (-not $ServerName)    { throw "-ResetTargetSchema requires -ServerName." }
    if (-not $DatabaseName)  { throw "-ResetTargetSchema requires -DatabaseName." }
    if (-not $TargetSqlUser) { throw "-ResetTargetSchema requires -TargetSqlUser (a SQL login on the target DB)." }
    if (-not (Test-Path $ResetSchemaScript)) { throw "Reset script not found: $ResetSchemaScript" }

    $fqdn = "$ServerName.database.windows.net"
    Write-Host ""
    Write-Host "Reset-target-schema plan (subscription $SubscriptionId):" -ForegroundColor Cyan
    Write-Host "  - Delete prior migration resource for DB '$DatabaseName' (if any)" -ForegroundColor Yellow
    Write-Host "  - Drop ALL schema + data inside DB '$DatabaseName' on '$fqdn'" -ForegroundColor Yellow
    Write-Host "  (the database, logical server, and DMS are KEPT)" -ForegroundColor DarkGray
    Write-Host ""

    if (-not $Force) {
        $answer = Read-Host "This drops every object and ALL rows in '$DatabaseName'. Type 'reset' to proceed"
        if ($answer -ne 'reset') { Write-Host "Aborted — nothing was changed." -ForegroundColor Green; return }
    }

    # 1) Remove the prior (completed/in-progress) migration resource so a new Phase 4
    #    data copy can attach to this target DB.
    az datamigration sql-db show -g $ResourceGroup --sqldb-instance-name $ServerName --target-db-name $DatabaseName -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> Deleting prior migration resource for '$DatabaseName'" -ForegroundColor Cyan
        az datamigration sql-db delete -g $ResourceGroup --sqldb-instance-name $ServerName --target-db-name $DatabaseName --force true --yes --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw "az datamigration sql-db delete failed (exit $LASTEXITCODE)." }
    }
    else {
        Write-Host "==> No migration resource attached to '$DatabaseName' — skipping." -ForegroundColor DarkGray
    }

    # 2) Drop all user objects (data-plane). Prompt for the target SQL password and
    #    pass it to sqlcmd via SQLCMDPASSWORD so it never appears on the command line.
    $securePwd = Read-Host -Prompt "Target SQL password for '$TargetSqlUser'" -AsSecureString
    $env:SQLCMDPASSWORD = [System.Net.NetworkCredential]::new('', $securePwd).Password
    try {
        Write-Host "==> Dropping all schema + data in '$DatabaseName' on '$fqdn'" -ForegroundColor Cyan
        sqlcmd -S $fqdn -d $DatabaseName -U $TargetSqlUser -C -b -i $ResetSchemaScript
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd reset failed (exit $LASTEXITCODE)." }
    }
    finally {
        Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue
        $securePwd = $null
    }

    Write-Host ""
    Write-Host "Target DB '$DatabaseName' emptied; database, server, and DMS kept." -ForegroundColor Green
    Write-Host "Zone redundancy preserved (DB was not recreated). Run Phase 4 again now — skip Phase 2:" -ForegroundColor Green
    Write-Host "  .\04-migrate.ps1 ... -SourceSqlUser <src-login>" -ForegroundColor Green
    Stop-PhaseLog
    return
}

# --- Build the plan ---------------------------------------------------------
$plan = [System.Collections.Generic.List[string]]::new()
if ($DeleteResourceGroup) {
    $plan.Add("DELETE resource group '$ResourceGroup' and ALL resources in it")
}
else {
    if ($DatabaseName) {
        if (-not $ServerName) { throw "-DatabaseName requires -ServerName." }
        $plan.Add("Delete database '$DatabaseName' on server '$ServerName'")
    }
    if ($DmsName -and -not $KeepDms) { $plan.Add("Delete DMS '$DmsName'") }
    if ($DmsName -and $KeepDms)      { Write-Host "  (keeping DMS '$DmsName' — -KeepDms)" -ForegroundColor DarkGray }
    if ($ServerName -and -not $KeepServer) { $plan.Add("Delete logical server '$ServerName' (and any remaining databases on it)") }
    if ($plan.Count -eq 0) {
        throw "Nothing to do. Specify -DatabaseName / -DmsName / -ServerName, or -DeleteResourceGroup."
    }
}

Write-Host ""
Write-Host "Teardown plan (subscription $SubscriptionId):" -ForegroundColor Cyan
foreach ($item in $plan) { Write-Host "  - $item" -ForegroundColor Yellow }
Write-Host ""

# --- Confirm ----------------------------------------------------------------
if (-not $Force) {
    $answer = Read-Host "This is destructive. Type 'delete' to proceed"
    if ($answer -ne 'delete') {
        Write-Host "Aborted — nothing was deleted." -ForegroundColor Green
        return
    }
}

$failures = [System.Collections.Generic.List[string]]::new()

# --- Whole resource group ---------------------------------------------------
if ($DeleteResourceGroup) {
    Write-Host "==> Deleting resource group '$ResourceGroup'" -ForegroundColor Cyan
    az group delete --name $ResourceGroup --yes --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "az group delete failed (exit $LASTEXITCODE)." }
    Write-Host "Resource group '$ResourceGroup' deleted." -ForegroundColor Green
    return
}

# --- 1. Target database -----------------------------------------------------
if ($DatabaseName -and $ServerName) {
    az sql db show -g $ResourceGroup -s $ServerName -n $DatabaseName -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> Deleting database '$DatabaseName' on '$ServerName'" -ForegroundColor Cyan
        az sql db delete -g $ResourceGroup -s $ServerName -n $DatabaseName --yes --only-show-errors
        if ($LASTEXITCODE -ne 0) { $failures.Add("database '$DatabaseName'") }
    }
    else {
        Write-Host "==> Database '$DatabaseName' not found — skipping." -ForegroundColor DarkGray
    }
}

# --- 2. DMS -----------------------------------------------------------------
if ($DmsName -and -not $KeepDms) {
    az datamigration sql-service show -g $ResourceGroup --name $DmsName -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> Deleting DMS '$DmsName'" -ForegroundColor Cyan
        az datamigration sql-service delete -g $ResourceGroup --name $DmsName --yes --only-show-errors
        if ($LASTEXITCODE -ne 0) { $failures.Add("DMS '$DmsName'") }
    }
    else {
        Write-Host "==> DMS '$DmsName' not found — skipping." -ForegroundColor DarkGray
    }
}

# --- 3. Logical server ------------------------------------------------------
if ($ServerName -and -not $KeepServer) {
    az sql server show -g $ResourceGroup -n $ServerName -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "==> Deleting logical server '$ServerName'" -ForegroundColor Cyan
        az sql server delete -g $ResourceGroup -n $ServerName --yes --only-show-errors
        if ($LASTEXITCODE -ne 0) { $failures.Add("server '$ServerName'") }
    }
    else {
        Write-Host "==> Server '$ServerName' not found — skipping." -ForegroundColor DarkGray
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    throw "Teardown completed with errors deleting: $($failures -join ', '). Re-run after resolving (e.g. an in-progress migration must finish/cancel before its DB or DMS can be deleted)."
}
Write-Host "Teardown complete. Re-run the runbook from Phase 2 to provision a fresh target." -ForegroundColor Green
Write-Host "(To re-run only Phase 4 without dropping the DB, use -ResetTargetSchema instead.)" -ForegroundColor DarkGray
Stop-PhaseLog

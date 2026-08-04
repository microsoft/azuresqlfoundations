<#
.SYNOPSIS
  Phase 4 — migrate the database. A pre-flight (4pre) scans the source for DMS
  data-copy limitations first, then two sub-steps in one phase:
    4a) deploy the schema to the target (tables must exist before any data copies)
    4b) copy the data via the DMS + SHIR, then wait for it to finish.
.DESCRIPTION
  For an Azure SQL Database target the DMS data-copy step does NOT create tables, so
  the schema is deployed first (`az datamigration sql-server-schema`), then the data
  migration is started (`az datamigration sql-db create`) and polled to completion
  (`az datamigration sql-db show`).

  You are prompted once for the target SQL password (masked SecureString); it is
  reused for both sub-steps. The source uses Windows auth on localhost.

  Schema sub-step options (-SchemaAction):
    MigrateSchema  (default) deploy schema objects straight to the target
    GenerateScript           emit an editable T-SQL script to -OutputFolder, then stop
    DeploySchema             run a previously generated script (-InputScriptFilePath)

  Staged schema-then-data flow:
    -SchemaOnly  deploy the schema (4a) and STOP before the data copy, so you can
                 verify the target with SSMS Schema Compare. Resume the data copy
                 with a second run using -SkipSchema -SourceSqlUser <login>.

.EXAMPLE
  .\04-migrate.ps1 -SubscriptionId <sub> -ResourceGroup <rg> -DmsName <dms-name> `
      -SourceServer localhost -SourceDatabase <db> `
      -TargetServer <server> -TargetServerFqdn <server>.database.windows.net `
      -TargetDatabase <db> -TargetSqlUser <user>

.EXAMPLE
  # Copy only specific tables:
  .\04-migrate.ps1 ... -TableList '[dbo].[Orders]','[dbo].[Customers]'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$DmsName,

    [Parameter(Mandatory)] [string]$SourceServer,       # 'localhost' on the SHIR host
    [Parameter(Mandatory)] [string]$SourceDatabase,

    [Parameter(Mandatory)] [string]$TargetServer,       # logical server name (no domain suffix)
    [Parameter(Mandatory)] [string]$TargetServerFqdn,   # e.g. myserver.database.windows.net
    [Parameter(Mandatory)] [string]$TargetDatabase,

    [Parameter(Mandatory)]
    [string]$TargetSqlUser,

    # Optional: scope the data copy to specific tables. Omit to copy all tables.
    [string[]]$TableList,

    # Optional: use SQL Authentication for the SOURCE data copy (instead of Windows
    # auth). Required when the SHIR service account cannot use Windows auth against
    # the source. Prompts for this login's password at runtime. The local schema
    # step still uses Windows auth.
    [string]$SourceSqlUser,

    # Skip the 4a schema deploy (e.g. the schema was already deployed by a prior run).
    [switch]$SkipSchema,

    # Deploy the schema (4a) and STOP before the data copy, so you can verify the
    # target with SSMS Schema Compare. Resume later with -SkipSchema -SourceSqlUser.
    [switch]$SchemaOnly,

    # Don't pause for confirmation when the schema deploy reports object-level
    # errors (e.g. a source-only migration login that collides with the target
    # admin). By default Phase 4 lists the errors and prompts before the data copy.
    [switch]$ContinueOnSchemaError,

    # Phase 4 pre-flight: scan the source for DMS data-copy limitations (computed
    # columns, double-byte table names, large LOBs, reserved-word/semicolon db
    # names, >100k tables). Runs FIRST, before schema/data. Use -SkipDmsLimitationCheck
    # to bypass; a BLOCKER verdict stops the migration unless you also pass -Force.
    [string]$DmsCheckScript = (Join-Path $PSScriptRoot 'check-dms-limitations.sql'),
    [switch]$SkipDmsLimitationCheck,
    [switch]$Force,

    # Schema sub-step behaviour.
    [ValidateSet('MigrateSchema', 'GenerateScript', 'DeploySchema')]
    [string]$SchemaAction = 'MigrateSchema',
    [string]$OutputFolder        = 'C:\dms\schema',
    [string]$InputScriptFilePath = '',

    # Data sub-step monitor poll interval.
    [int]$IntervalSeconds = 30,

    # On each data-copy poll, also print per-table progress (rows read/copied,
    # bytes) from the migration status detail's listOfCopyProgressDetails. The list
    # is empty until the copy phase actually starts streaming tables, then fills in
    # per table. Coarse migrationStatus/migrationState is always printed regardless.
    [switch]$ShowCopyProgress
)

$ErrorActionPreference = 'Stop'

# Tee all console output to a timestamped log file (read it instead of the terminal).
. (Join-Path $PSScriptRoot '_log.ps1')
Start-PhaseLog '04-migrate'
trap { Stop-PhaseLog; break }

# Ensure the Azure CLI is on PATH even right after a fresh install/upgrade.
. (Join-Path $PSScriptRoot '_resolve-az.ps1')

# Control-plane calls (ARM) — require an authenticated az context (az login).
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "az account set failed (exit $LASTEXITCODE) — run 'az login' first." }

# --- 4 pre) DMS limitation pre-check (source) ---------------------------------
# These are migration-TOOL limitations, not target incompatibilities, so the
# Phase 1 assessment does not surface them. Catch them BEFORE the offline cutover.
if (-not $SkipDmsLimitationCheck) {
    if (-not (Test-Path $DmsCheckScript)) { throw "DMS check script not found: $DmsCheckScript" }
    Write-Host "==> 4pre) DMS limitation pre-check on source [$SourceDatabase]" -ForegroundColor Cyan
    $checkOut = & sqlcmd -S $SourceServer -E -d $SourceDatabase -b -i $DmsCheckScript 2>&1
    if ($LASTEXITCODE -ne 0) { throw "DMS limitation pre-check failed to run (sqlcmd exit $LASTEXITCODE): $checkOut" }
    $checkOut | ForEach-Object { Write-Host $_ }
    if ($checkOut -match 'DMS PRE-CHECK VERDICT: BLOCKERS FOUND') {
        if ($Force) {
            Write-Host "==> BLOCKERS found but -Force was passed; continuing anyway." -ForegroundColor Yellow
        }
        else {
            throw "DMS limitation pre-check found BLOCKERS (see above). Fix them, or re-run with -Force to override, or -SkipDmsLimitationCheck to skip the check."
        }
    }
}

# Prompt once for the target password without echoing it; reused by both sub-steps.
$securePwd = Read-Host -Prompt "Target SQL password for '$TargetSqlUser'" -AsSecureString
$plainPwd  = [System.Net.NetworkCredential]::new('', $securePwd).Password

# When the source uses SQL auth (SHIR cannot use Windows auth), prompt for it too.
$plainSrcPwd = $null
if ($SourceSqlUser) {
    $secureSrcPwd = Read-Host -Prompt "Source SQL password for '$SourceSqlUser'" -AsSecureString
    $plainSrcPwd  = [System.Net.NetworkCredential]::new('', $secureSrcPwd).Password
}

try {
    if ($SkipSchema) {
        Write-Host "==> 4a) Schema: SKIPPED (-SkipSchema)" -ForegroundColor Yellow
    }
    else {
    # --- 4a) Schema ---------------------------------------------------------------
    $srcConn = "Server=$SourceServer;Initial Catalog=$SourceDatabase;Integrated Security=True;TrustServerCertificate=True"
    $tgtConn = "Server=$TargetServerFqdn;Initial Catalog=$TargetDatabase;User ID=$TargetSqlUser;Password=$plainPwd;TrustServerCertificate=True"

    $schemaArgs = @(
        'datamigration', 'sql-server-schema',
        '--action', $SchemaAction,
        '--src-sql-connection-str', $srcConn,
        '--tgt-sql-connection-str', $tgtConn
    )
    if ($SchemaAction -ne 'MigrateSchema') { $schemaArgs += @('--output-folder', $OutputFolder) }
    if ($SchemaAction -eq 'DeploySchema') {
        if (-not $InputScriptFilePath) { throw "DeploySchema requires -InputScriptFilePath." }
        $schemaArgs += @('--input-script-file-path', $InputScriptFilePath)
    }

    Write-Host "==> 4a) Schema '$SchemaAction': $SourceDatabase -> $TargetDatabase" -ForegroundColor Cyan

    # Snapshot the schema-migration event log so we can report ONLY this run's
    # object-level deploy errors afterward (the tool appends to a per-day log).
    $schemaLogDir = Join-Path $env:LOCALAPPDATA 'Microsoft\SqlSchemaMigration\Logs'
    $preLog = Get-ChildItem $schemaLogDir -Filter 'SchemaMigrationEvent-*.log' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $preLogPath  = if ($preLog) { $preLog.FullName } else { $null }
    $preLogLines = if ($preLog) { (Get-Content -LiteralPath $preLog.FullName).Count } else { 0 }

    # The downloaded SqlSchemaMigration.exe targets .NET 6.0 (out of support). Roll it
    # forward onto a newer installed runtime (8/9/10) instead of installing .NET 6.
    $prevRollFwd = $env:DOTNET_ROLL_FORWARD
    $env:DOTNET_ROLL_FORWARD = 'LatestMajor'
    try { az @schemaArgs }
    finally { $env:DOTNET_ROLL_FORWARD = $prevRollFwd }
    if ($LASTEXITCODE -ne 0) { throw "sql-server-schema failed (exit $LASTEXITCODE)." }

    if ($SchemaAction -eq 'GenerateScript') {
        Write-Host "Schema script written to $OutputFolder. Review/edit it, then re-run with -SchemaAction DeploySchema -InputScriptFilePath <file> to continue." -ForegroundColor Yellow
        Stop-PhaseLog
        return
    }

    # Surface per-object schema-deploy errors as WARNINGS (they're often benign,
    # e.g. a source-only migration login that collides with the target admin),
    # then let the operator decide whether to proceed to the data copy.
    $postLog = Get-ChildItem $schemaLogDir -Filter 'SchemaMigrationEvent-*.log' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $schemaErrors = @()
    if ($postLog) {
        $allLines = Get-Content -LiteralPath $postLog.FullName
        $newLines = if ($postLog.FullName -eq $preLogPath) { $allLines | Select-Object -Skip $preLogLines } else { $allLines }
        $schemaErrors = @(
            $newLines |
            Where-Object { $_ -match 'EventTraceSource Error' } |
            ForEach-Object { ($_ -replace '^EventTraceSource Error:\s*\d+\s*:\s*\S+\s+\S+\s+\S+\s*-\s*', '').Trim() }
        )
    }
    if ($schemaErrors.Count -gt 0) {
        Write-Host ''
        Write-Warning "Schema migration reported $($schemaErrors.Count) object-level error(s) (data NOT copied yet):"
        $n = 1
        foreach ($se in $schemaErrors) { Write-Host ('    [{0}] {1}' -f $n++, $se) -ForegroundColor Yellow }
        if ($postLog) { Write-Host "    Full log: $($postLog.FullName)" -ForegroundColor DarkGray }
        Write-Host ''
        if ($Force -or $ContinueOnSchemaError) {
            Write-Host '==> Proceeding to data copy despite schema errors (-Force/-ContinueOnSchemaError).' -ForegroundColor Yellow
        }
        else {
            $ans = Read-Host 'Proceed to DATA COPY anyway? [y/N]'
            if ($ans -notmatch '^(y|yes)$') {
                throw 'Stopped after schema migration at your request. Review the errors above; fix if needed, then re-run (add -SkipSchema to avoid re-deploying schema).'
            }
        }
    }
    else {
        Write-Host '==> 4a) Schema deployed with no object-level errors.' -ForegroundColor Green
    }
    }  # end else (schema not skipped)

    if ($SchemaOnly) {
        Write-Host '==> 4a complete. Stopping before the data copy (-SchemaOnly).' -ForegroundColor Yellow
        Write-Host '    Verify the target now with SSMS Schema Compare, then copy the data with:' -ForegroundColor Yellow
        Write-Host '    .\04-migrate.ps1 ... -SkipSchema -SourceSqlUser <source-login>' -ForegroundColor Yellow
        Stop-PhaseLog
        return
    }

    # --- 4b) Data -----------------------------------------------------------------
    $svc = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.DataMigration/sqlMigrationServices/$DmsName"
    $tgt = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Sql/servers/$TargetServer"

    # Source connection: SQL auth (SHIR) if -SourceSqlUser given, else Windows auth.
    if ($SourceSqlUser) {
        $srcAuth = @('authentication=SqlAuthentication', "user-name=$SourceSqlUser", "password=$plainSrcPwd")
    }
    else {
        $srcAuth = @('authentication=WindowsAuthentication', 'user-name=placeholder', 'password=placeholder')
    }

    $dataArgs = @(
        'datamigration', 'sql-db', 'create',
        '--resource-group', $ResourceGroup,
        '--sqldb-instance-name', $TargetServer,
        '--target-db-name', $TargetDatabase,
        '--source-database-name', $SourceDatabase,
        '--migration-service', $svc,
        '--scope', $tgt,
        '--source-sql-connection', "data-source=$SourceServer"
    )
    $dataArgs += $srcAuth
    $dataArgs += @('encrypt-connection=true', 'trust-server-certificate=true')
    $dataArgs += @(
        '--target-sql-connection',
            "data-source=$TargetServerFqdn", 'authentication=SqlAuthentication',
            "user-name=$TargetSqlUser", "password=$plainPwd",
            'encrypt-connection=true', 'trust-server-certificate=true'
    )
    if ($TableList -and $TableList.Count -gt 0) {
        $dataArgs += '--table-list'
        $dataArgs += $TableList
    }

    Write-Host "==> 4b) Data copy: $SourceDatabase -> $TargetDatabase (Hyperscale)" -ForegroundColor Cyan
    az @dataArgs
    if ($LASTEXITCODE -ne 0) { throw "sql-db create failed (exit $LASTEXITCODE)." }

    # Poll until the migration reaches a terminal state.
    $terminal = @('Succeeded', 'Failed', 'Canceled')
    do {
        $json = az datamigration sql-db show `
            --resource-group $ResourceGroup `
            --sqldb-instance-name $TargetServer `
            --target-db-name $TargetDatabase `
            --expand MigrationStatusDetails -o json
        if ($LASTEXITCODE -ne 0) { throw "sql-db show failed (exit $LASTEXITCODE)." }
        $props  = ($json | ConvertFrom-Json).properties
        $status = $props.migrationStatus
        Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] migrationStatus = $status | provisioningState = $($props.provisioningState)" -ForegroundColor Cyan
        if ($props.migrationFailureError -and $props.migrationFailureError.message) {
            Write-Host "Error: $($props.migrationFailureError.message)" -ForegroundColor Red
        }
        if ($ShowCopyProgress) {
            $detail = $props.migrationStatusDetails
            $copy   = @($detail.listOfCopyProgressDetails)
            if ($copy.Count -gt 0) {
                # Fixed widths keep the table inside a narrow (~60-col) terminal so the
                # row counts don't wrap vertically. Table names drop the [schema]. prefix
                # and brackets; the row count is thousands-separated for readability.
                # Only rowsRead is shown — rowsCopied converges to the same value, and a
                # second number column overflows; 05-validate does the authoritative
                # target-vs-source row-count comparison.
                $copy |
                    Sort-Object -Property @{ Expression = { [int64]([string]$_.rowsRead -replace '\D','0') } } -Descending |
                    Format-Table `
                        @{ N = 'table';  E = { ($_.tableName -replace '^\[[^\]]+\]\.', '') -replace '[\[\]]', '' }; Width = 26 },
                        @{ N = 'status'; E = { $_.status }; Width = 13 },
                        @{ N = 'rowsRead'; E = { if ($null -ne $_.rowsRead) { '{0:N0}' -f [int64]([string]$_.rowsRead -replace '\D','0') } }; Width = 14; Align = 'right' } |
                    Out-Host
            }
            else {
                Write-Host "    (no per-table progress yet — migrationState: $($detail.migrationState))" -ForegroundColor DarkGray
            }
        }
        if ($terminal -contains $status) { break }
        Start-Sleep -Seconds $IntervalSeconds
    } while ($true)

    if ($status -ne 'Succeeded') {
        throw "Data migration did not succeed (status = $status). See the details above."
    }
}
finally {
    $plainPwd   = $null
    $schemaArgs = $null
    $dataArgs   = $null
}

Write-Host ""
Write-Host "Migration complete (schema + data). Next: .\05-validate.ps1" -ForegroundColor Green
Stop-PhaseLog

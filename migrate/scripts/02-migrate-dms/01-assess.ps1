<#
.SYNOPSIS
  Phase 1 — assess the source SQL Server for migration to Azure SQL Database
  and list any issues/blockers that would affect the migration. Read-only.

.DESCRIPTION
  Runs the local `az datamigration get-assessment` console app against the source,
  then parses the report and prints the target-readiness summary plus every
  assessment finding (feature incompatibilities, warnings, blockers).

  Creates no Azure resources and needs no `az login`. Easiest to run ON the source
  VM so the source is `localhost` with Windows auth.

  SKU sizing / performance-data collection is out of scope here — use
  `az datamigration performance-data-collection` + `get-sku-recommendation` if needed.

.EXAMPLE
  .\01-assess.ps1 -SourceConnectionString 'Data Source=localhost;Initial Catalog=master;Integrated Security=True;TrustServerCertificate=True'

.EXAMPLE
  .\01-assess.ps1 -SourceConnectionString '<conn>' -TargetPlatform Any   # all target platforms
#>
[CmdletBinding()]
param(
    # Source connection string (ADO.NET). Windows or SQL auth; point at the master
    # DB of the source instance. Run on the source VM so the data source is localhost.
    [Parameter(Mandatory)]
    [string]$SourceConnectionString,

    [string]$AssessmentOutputFolder = 'C:\dms\assessment',

    # Which target platform's findings to show. Default = AzureSqlDatabase (Hyperscale is a tier of it).
    [ValidateSet('AzureSqlDatabase', 'AzureSqlManagedInstance', 'Any')]
    [string]$TargetPlatform = 'AzureSqlDatabase',

    # T-SQL that proves whether Service Broker is actually used vs merely enabled.
    [string]$BrokerCheckScript = (Join-Path $PSScriptRoot 'verify-service-broker.sql')
)

$ErrorActionPreference = 'Stop'

# Tee all console output to a timestamped log file (read it instead of the terminal).
. (Join-Path $PSScriptRoot '_log.ps1')
Start-PhaseLog '01-assess'
trap { Stop-PhaseLog; break }

# Ensure the Azure CLI is on PATH even right after a fresh install/upgrade.
. (Join-Path $PSScriptRoot '_resolve-az.ps1')

Write-Host "==> Running SQL assessment -> $AssessmentOutputFolder" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $AssessmentOutputFolder | Out-Null
az datamigration get-assessment `
    --connection-string $SourceConnectionString `
    --output-folder $AssessmentOutputFolder `
    --overwrite
if ($LASTEXITCODE -ne 0) { throw "get-assessment failed (exit $LASTEXITCODE)." }

# --- Parse the report and surface migration issues -------------------------------
$report = Get-ChildItem $AssessmentOutputFolder -Filter 'SqlAssessmentReport*.json' |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $report) { throw "No SqlAssessmentReport*.json found in $AssessmentOutputFolder." }

$j = Get-Content $report.FullName -Raw | ConvertFrom-Json

# RuleMetadata is a flattened "@{Key=value; Key=value; ...}" string. Pull one field.
function Get-RuleField([string]$meta, [string]$key) {
    if ($meta -and ($meta -match "$key=([^;]*)")) { return $Matches[1].Trim() }
    return ''
}

# Pull the server name out of the (ADO.NET) source connection string for sqlcmd.
$csb = [System.Data.Common.DbConnectionStringBuilder]::new()
$csb.set_ConnectionString($SourceConnectionString)
$sourceServer =
    if ($csb.ContainsKey('Data Source')) { [string]$csb['Data Source'] }
    elseif ($csb.ContainsKey('Server')) { [string]$csb['Server'] }
    else { 'localhost' }

foreach ($server in $j.Servers) {
    Write-Host ''
    Write-Host "Server: $($server.Properties.ServerName)  ($($server.Properties.ServerVersion), $($server.Properties.ServerEdition))" -ForegroundColor White

    # Target-readiness summary
    foreach ($plat in 'AzureSqlDatabase', 'AzureSqlManagedInstance') {
        if ($TargetPlatform -ne 'Any' -and $TargetPlatform -ne $plat) { continue }
        $tr = $server.TargetReadinesses.$plat
        if (-not $tr) { continue }
        $color = if ($tr.RecommendationStatus -eq 'Ready') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,-26} {1}  (blockers: {2}, ready: {3}/{4})" -f `
                $plat, $tr.RecommendationStatus, $tr.NumberOfServerBlockerIssues, `
                $tr.NumberOfDatabasesReadyForMigration, $tr.TotalNumberOfDatabases) -ForegroundColor $color
    }

    # Collect findings (server + database scope), skip empty placeholders
    $findings = @()
    if ($server.ServerAssessments) { $findings += $server.ServerAssessments }
    foreach ($db in $server.Databases) {
        if ($db.DatabaseAssessments) { $findings += $db.DatabaseAssessments }
    }
    $findings = $findings | Where-Object { $_.FeatureId }
    if ($TargetPlatform -ne 'Any') {
        $findings = $findings | Where-Object { $_.AppliesToMigrationTargetPlatform -eq $TargetPlatform }
    }

    if (-not $findings -or $findings.Count -eq 0) {
        Write-Host "  No migration issues found for $TargetPlatform." -ForegroundColor Green
        continue
    }

    Write-Host ''
    Write-Host "  Migration issues ($($findings.Count)):" -ForegroundColor Cyan
    $i = 0
    foreach ($f in $findings) {
        $i++
        # IssueCategory is the classification DMA surfaces (Warning / Issue / ...).
        $category = if ($f.IssueCategory) { $f.IssueCategory } else { 'Unknown' }
        $desc = Get-RuleField $f.RuleMetadata 'Description'
        $msg  = Get-RuleField $f.RuleMetadata 'Message'
        $catColor = switch ($category) { 'Issue' { 'Red' } 'Warning' { 'Yellow' } default { 'Gray' } }
        Write-Host ("  [{0}] {1}  ({2}) -> {3}" -f $i, $f.FeatureId, $category, $f.AppliesToMigrationTargetPlatform) -ForegroundColor $catColor
        if ($desc) { Write-Host "       $desc" -ForegroundColor Gray }
        if ($f.ImpactedObjects) {
            $names = @($f.ImpactedObjects) | Where-Object { $_.Name } |
                     ForEach-Object { "$($_.Name) ($($_.ObjectType))" }
            if ($names) { Write-Host "       Impacted: $($names -join ', ')" -ForegroundColor Gray }
        }
        if ($msg) { Write-Host "       Fix: $msg" -ForegroundColor Gray }
    }

    # Service Broker is enabled by default at CREATE DATABASE, so DMS flags the
    # option whether or not it is used. Verify the real state on the source.
    $brokerFindings = $findings | Where-Object { $_.FeatureId -eq 'ServiceBroker' }
    if ($brokerFindings -and (Test-Path $BrokerCheckScript)) {
        $brokerDbs = @($brokerFindings | ForEach-Object { @($_.ImpactedObjects) } |
            Where-Object { $_.Name -and $_.ObjectType -eq 'Database' } |
            ForEach-Object { $_.Name } | Select-Object -Unique)
        Write-Host ''
        Write-Host "  Service Broker verification (enabled vs. actually used):" -ForegroundColor Cyan
        foreach ($bdb in $brokerDbs) {
            sqlcmd -S $sourceServer -E -C -d $bdb -h -1 -W -i $BrokerCheckScript |
                ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }
    }
}

Write-Host ''
Write-Host "Full report: $($report.FullName)" -ForegroundColor Green
Write-Host "Assessment phase complete. Next: 02-provision.ps1" -ForegroundColor Green
Stop-PhaseLog

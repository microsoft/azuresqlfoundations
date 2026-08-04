<#
.SYNOPSIS
  Phase 5 — validate the migration by comparing object counts and per-table row
  counts between the source and the migrated target. Read-only.

.DESCRIPTION
  Runs validate-migration.sql against BOTH the source (Windows auth on localhost)
  and the target (SQL auth on the Azure SQL logical server) via sqlcmd, prints each
  snapshot, then compares the totals (table count + row count) and reports PASS/FAIL.

  Needs sqlcmd on PATH and no `az login`. The source read uses Windows auth on
  localhost; you are prompted for the target SQL password (masked SecureString).

  This is the scripted form of the manual SSMS workflow described at the top of
  validate-migration.sql — run that .sql by hand in SSMS if you prefer.

.EXAMPLE
  .\05-validate.ps1 -SourceDatabase <db> `
      -TargetServerFqdn <server>.database.windows.net -TargetDatabase <db> -TargetSqlUser <user>
#>
[CmdletBinding()]
param(
    [string]$SourceServer = 'localhost',          # source is localhost on the SHIR host

    [Parameter(Mandatory)] [string]$SourceDatabase,

    [Parameter(Mandatory)] [string]$TargetServerFqdn,   # e.g. myserver.database.windows.net
    [Parameter(Mandatory)] [string]$TargetDatabase,
    [Parameter(Mandatory)] [string]$TargetSqlUser
)

$ErrorActionPreference = 'Stop'

# Tee all console output to a timestamped log file (read it instead of the terminal).
. (Join-Path $PSScriptRoot '_log.ps1')
Start-PhaseLog '05-validate'
trap { Stop-PhaseLog; break }

$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
if (-not $sqlcmd) {
    throw "sqlcmd not found on PATH. Install the SQL command-line tools (https://aka.ms/sqlcmd) or run validate-migration.sql by hand in SSMS."
}

$script = Join-Path $PSScriptRoot 'validate-migration.sql'
if (-not (Test-Path $script)) { throw "validate-migration.sql not found next to this script." }

$securePwd = Read-Host -Prompt "Target SQL password for '$TargetSqlUser'" -AsSecureString
$plainPwd  = [System.Net.NetworkCredential]::new('', $securePwd).Password

# Compact totals query (table count + total rows) used for the PASS/FAIL comparison.
$totalsQuery = @"
SET NOCOUNT ON;
SELECT CONVERT(varchar(20), COUNT(DISTINCT t.object_id)) + '|' + CONVERT(varchar(30), ISNULL(SUM(p.rows),0))
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
WHERE t.name NOT LIKE '\_\_migration%' ESCAPE '\';
"@

function Get-Totals([string[]]$cmdArgs) {
    $out = & sqlcmd @cmdArgs -h -1 -W -Q $totalsQuery
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed (exit $LASTEXITCODE)." }
    $line = ($out | Where-Object { $_ -match '^\d+\|\d+$' } | Select-Object -First 1)
    if (-not $line) { throw "Could not parse totals from sqlcmd output." }
    $parts = $line.Trim().Split('|')
    [pscustomobject]@{ Tables = [int]$parts[0]; Rows = [long]$parts[1] }
}

try {
    Write-Host "==> SOURCE snapshot: [$SourceDatabase] on $SourceServer" -ForegroundColor Cyan
    & sqlcmd -S $SourceServer -E -C -d $SourceDatabase -i $script
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd against source failed (exit $LASTEXITCODE)." }

    Write-Host "`n==> TARGET snapshot: [$TargetDatabase] on $TargetServerFqdn" -ForegroundColor Cyan
    & sqlcmd -S $TargetServerFqdn -U $TargetSqlUser -P $plainPwd -C -d $TargetDatabase -i $script
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd against target failed (exit $LASTEXITCODE)." }

    $src = Get-Totals @('-S', $SourceServer, '-E', '-C', '-d', $SourceDatabase)
    $tgt = Get-Totals @('-S', $TargetServerFqdn, '-U', $TargetSqlUser, '-P', $plainPwd, '-C', '-d', $TargetDatabase)
}
finally {
    $plainPwd = $null
}

Write-Host "`n==> Totals" -ForegroundColor Cyan
Write-Host ("    source : {0,6} tables  {1,15} rows" -f $src.Tables, $src.Rows)
Write-Host ("    target : {0,6} tables  {1,15} rows" -f $tgt.Tables, $tgt.Rows)

if ($src.Tables -eq $tgt.Tables -and $src.Rows -eq $tgt.Rows) {
    Write-Host "VALIDATION PASSED — table and row counts match." -ForegroundColor Green
}
else {
    Write-Host "VALIDATION FAILED — counts differ. Review the per-table snapshots above." -ForegroundColor Red
    Stop-PhaseLog
    exit 1
}

Stop-PhaseLog

<#
.SYNOPSIS
    Runs named replica reporting queries to verify workload isolation.

.DESCRIPTION
    Runs 02-named-replica-reporting.sql against the named replica using sqlsim
    with Azure token auth. Validates that the replica is READ_ONLY and runs
    underwriter dashboard, credit risk, and portfolio analytics queries.

    This step is OPTIONAL — skip it if no named replica is configured.

    RE-RUNNABLE: Read-only queries, no schema changes.

.PARAMETER Server
    Azure SQL server (e.g., zavafinsql.database.windows.net). Required.

.PARAMETER Database
    Named replica database name. Required.

.PARAMETER SqlsimPath
    Path to sqlsim.exe. Default: C:\bwsql\sqlsimtools\sqlsim\build\x64\Release\sqlsim.exe

.EXAMPLE
    .\step2-replica-queries.ps1 -Server zavafinsql.database.windows.net -Database zavalending_NamedReplica
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,

    [Parameter(Mandatory=$true)]
    [string]$Database,
    [string]$SqlsimPath = "C:\bwsql\sqlsimtools\sqlsim\build\x64\Release\sqlsim.exe"
)

$ErrorActionPreference = "Stop"

# ── Validate sqlsim ──
if (-not (Test-Path $SqlsimPath)) {
    Write-Host "ERROR: sqlsim.exe not found at: $SqlsimPath" -ForegroundColor Red
    exit 1
}

# ── Validate SQL file ──
$sqlFile = Join-Path $PSScriptRoot "02-named-replica-reporting.sql"
if (-not (Test-Path $sqlFile)) {
    Write-Host "ERROR: SQL file not found: $sqlFile" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Step 2: Named Replica Queries (optional)"    -ForegroundColor Cyan
Write-Host " Server:   $Server"                           -ForegroundColor Cyan
Write-Host " Replica:  $Database"                         -ForegroundColor Cyan
Write-Host " Script:   02-named-replica-reporting.sql"    -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Acquire Azure token ──
Write-Host "Acquiring Azure access token..." -ForegroundColor Yellow
$token = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token | ConvertFrom-SecureString -AsPlainText
if (-not $token) {
    Write-Host "ERROR: Could not acquire Azure access token." -ForegroundColor Red
    Write-Host "Run: Connect-AzAccount" -ForegroundColor Red
    exit 1
}
Write-Host "  Token acquired" -ForegroundColor Green

# ── Run replica queries ──
Write-Host ""
Write-Host "Running 02-named-replica-reporting.sql against replica..." -ForegroundColor Yellow

& $SqlsimPath -S $Server -d $Database -T $token -i $sqlFile -v

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Replica queries completed successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "Validated:" -ForegroundColor White
    Write-Host "  - Replica is READ_ONLY" -ForegroundColor Gray
    Write-Host "  - Underwriter dashboard queries" -ForegroundColor Gray
    Write-Host "  - Credit risk + portfolio analytics" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Next: Run .\step3-add-narratives.ps1" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "ERROR: Replica queries failed (exit code $LASTEXITCODE)" -ForegroundColor Red
    Write-Host "  If no named replica exists, this step can be skipped." -ForegroundColor Yellow
    exit 1
}

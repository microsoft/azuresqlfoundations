<#
.SYNOPSIS
    Creates the scale demo tables via sqlsim.

.DESCRIPTION
    Runs 04-scale-schema.sql against ZavaLendingDB using sqlsim with Azure token auth.
    Creates LoanHistoryExpanded, LoanTransactions (CCI), MonthlyPortfolioSnapshot (CCI),
    and vw_AllLoans view. Safe: never modifies existing Demo 3 tables.

    RE-RUNNABLE: Uses DROP IF EXISTS + CREATE.

.PARAMETER Server
    Azure SQL server (e.g., zavafinsql.database.windows.net). Required.

.PARAMETER Database
    Target database name. Required.

.PARAMETER SqlsimPath
    Path to sqlsim.exe. Default: C:\bwsql\sqlsimtools\sqlsim\build\x64\Release\sqlsim.exe

.EXAMPLE
    .\step4-scale-schema.ps1 -Server zavafinsql.database.windows.net -Database zavalending
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
$sqlFile = Join-Path $PSScriptRoot "04-scale-schema.sql"
if (-not (Test-Path $sqlFile)) {
    Write-Host "ERROR: Schema file not found: $sqlFile" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Scale Schema Setup — Zava Lending"          -ForegroundColor Cyan
Write-Host " Server:   $Server"                           -ForegroundColor Cyan
Write-Host " Database: $Database"                         -ForegroundColor Cyan
Write-Host " Script:   $sqlFile"                          -ForegroundColor Cyan
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

# ── Run schema script ──
Write-Host ""
Write-Host "Running 04-scale-schema.sql..." -ForegroundColor Yellow

& $SqlsimPath -S $Server -d $Database -T $token -i $sqlFile -v

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Schema created successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "Tables created:" -ForegroundColor White
    Write-Host "  - dbo.LoanHistoryExpanded    (rowstore, for 500K expanded loans)" -ForegroundColor Gray
    Write-Host "  - dbo.LoanTransactions       (columnstore CCI, for ~50M transactions)" -ForegroundColor Gray
    Write-Host "  - dbo.MonthlyPortfolioSnapshot (columnstore CCI, for ~50K snapshots)" -ForegroundColor Gray
    Write-Host "  - dbo.vw_AllLoans            (UNION view: LoanHistory + LoanHistoryExpanded)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Next: Run .\step5-generate-data.ps1 to generate CSV data files" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "ERROR: Schema creation failed (exit code $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}

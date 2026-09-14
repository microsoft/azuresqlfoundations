<#
.SYNOPSIS
    Creates the base Zava Lending database schema and sample data.

.DESCRIPTION
    Runs 01-setup-zava-lending-db.sql against Azure SQL Hyperscale using sqlsim
    with Azure token auth. Creates Applicants (1,000 rows), LoanHistory (1,000 rows),
    LoanApplications, and LoanDecisions tables.

    RE-RUNNABLE: Uses DROP IF EXISTS + CREATE.

.PARAMETER Server
    Azure SQL server (e.g., zavafinsql.database.windows.net). Required.

.PARAMETER Database
    Target database name. Required.

.PARAMETER SqlsimPath
    Path to sqlsim.exe. Default: C:\bwsql\sqlsimtools\sqlsim\build\x64\Release\sqlsim.exe

.EXAMPLE
    .\step1-setup-db.ps1 -Server zavafinsql.database.windows.net -Database zavalending
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
$sqlFile = Join-Path $PSScriptRoot "01-setup-zava-lending-db.sql"
if (-not (Test-Path $sqlFile)) {
    Write-Host "ERROR: SQL file not found: $sqlFile" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Step 1: Setup Database — Zava Lending"      -ForegroundColor Cyan
Write-Host " Server:   $Server"                           -ForegroundColor Cyan
Write-Host " Database: $Database"                         -ForegroundColor Cyan
Write-Host " Script:   01-setup-zava-lending-db.sql"      -ForegroundColor Cyan
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

# ── Run setup script ──
Write-Host ""
Write-Host "Running 01-setup-zava-lending-db.sql..." -ForegroundColor Yellow

& $SqlsimPath -S $Server -d $Database -T $token -i $sqlFile -v

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Database setup completed successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "Tables created:" -ForegroundColor White
    Write-Host "  - dbo.Applicants       (1,000 rows)" -ForegroundColor Gray
    Write-Host "  - dbo.LoanHistory      (1,000 rows)" -ForegroundColor Gray
    Write-Host "  - dbo.LoanApplications (empty, populated by Demo 3)" -ForegroundColor Gray
    Write-Host "  - dbo.LoanDecisions    (empty, populated by Demo 3)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Next: Run .\step2-replica-queries.ps1 (or skip to .\step3-add-narratives.ps1)" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "ERROR: Database setup failed (exit code $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}

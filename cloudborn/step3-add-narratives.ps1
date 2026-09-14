<#
.SYNOPSIS
    Adds loan narrative text and full-text index to LoanHistory.

.DESCRIPTION
    Runs 03-add-loan-narratives.sql against ZavaLendingDB using sqlsim
    with Azure token auth. Adds the LoanNarrative NVARCHAR(4000) column,
    populates it with rich text descriptions, and creates a full-text index.

    Required for Demo 3 (vector search compares FT search vs embeddings).

    RE-RUNNABLE: Uses IF NOT EXISTS checks.

.PARAMETER Server
    Azure SQL server (e.g., zavafinsql.database.windows.net). Required.

.PARAMETER Database
    Target database name. Required.

.PARAMETER SqlsimPath
    Path to sqlsim.exe. Default: C:\bwsql\sqlsimtools\sqlsim\build\x64\Release\sqlsim.exe

.EXAMPLE
    .\step3-add-narratives.ps1 -Server zavafinsql.database.windows.net -Database zavalending
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
$sqlFile = Join-Path $PSScriptRoot "03-add-loan-narratives.sql"
if (-not (Test-Path $sqlFile)) {
    Write-Host "ERROR: SQL file not found: $sqlFile" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Step 3: Add Loan Narratives — Zava Lending" -ForegroundColor Cyan
Write-Host " Server:   $Server"                           -ForegroundColor Cyan
Write-Host " Database: $Database"                         -ForegroundColor Cyan
Write-Host " Script:   03-add-loan-narratives.sql"        -ForegroundColor Cyan
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

# ── Run narratives script ──
Write-Host ""
Write-Host "Running 03-add-loan-narratives.sql..." -ForegroundColor Yellow

& $SqlsimPath -S $Server -d $Database -T $token -i $sqlFile -v

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Loan narratives added successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "Completed:" -ForegroundColor White
    Write-Host "  - LoanNarrative column added to LoanHistory" -ForegroundColor Gray
    Write-Host "  - 100 narrative texts populated" -ForegroundColor Gray
    Write-Host "  - Full-text index created" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Next: Run .\step4-scale-schema.ps1" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "ERROR: Narrative setup failed (exit code $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}

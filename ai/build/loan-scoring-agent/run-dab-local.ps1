# ============================================================
# run-dab-local.ps1
# Run SQL MCP Server locally for testing/development
#
# Prerequisites:
#   - .NET 9+ SDK
#   - Network access to <your-server>.database.windows.net
#
# Usage:
#   .\run-dab-local.ps1                              # prompts for password
#   .\run-dab-local.ps1 -SqlPassword "YourPassword"  # non-interactive
#   .\run-dab-local.ps1 -UseAccessToken              # Entra ID token auth
#
# Once running, test with:
#   curl http://localhost:5000/health
#   curl http://localhost:5000/mcp
# ============================================================

param(
    [string]$SqlServer = "<your-server>.database.windows.net",
    [string]$SqlDatabase = "zavalending",
    [string]$SqlAdmin = "sqladmin",
    [string]$SqlPassword = "",
    [switch]$UseAccessToken
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ZavaFin Loan Scoring — Local DAB Server" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================
# Step 1: Check .NET SDK
# ============================================

Write-Host "Checking prerequisites..." -ForegroundColor Yellow

try {
    $dotnetVersion = dotnet --version 2>$null
    $majorVersion = [int]($dotnetVersion.Split('.')[0])
    if ($majorVersion -lt 9) {
        Write-Host "  ERROR: .NET $dotnetVersion found but 9+ required." -ForegroundColor Red
        Write-Host "  Install: winget install Microsoft.DotNet.SDK.9" -ForegroundColor White
        exit 1
    }
    Write-Host "  .NET SDK: $dotnetVersion" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: .NET SDK not found." -ForegroundColor Red
    Write-Host "  Install: winget install Microsoft.DotNet.SDK.9" -ForegroundColor White
    exit 1
}

# ============================================
# Step 2: Install DAB CLI (if not present)
# ============================================

Write-Host "Checking DAB CLI..." -ForegroundColor Yellow

# Check if dab is available as a global or local tool
$dabAvailable = $false
try {
    $dabVersion = dab --version 2>$null
    if ($dabVersion) {
        $dabAvailable = $true
        Write-Host "  DAB CLI: $dabVersion" -ForegroundColor Green
    }
} catch { }

if (-not $dabAvailable) {
    Write-Host "  DAB CLI not found. Installing..." -ForegroundColor Yellow
    
    # Install as a global tool for simplicity
    dotnet tool install --global microsoft.dataapibuilder --prerelease
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to install DAB CLI." -ForegroundColor Red
        Write-Host "  Try manually: dotnet tool install --global microsoft.dataapibuilder --prerelease" -ForegroundColor White
        exit 1
    }
    
    # Refresh PATH so dab is found
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "User") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
    
    $dabVersion = dab --version 2>$null
    Write-Host "  DAB CLI installed: $dabVersion" -ForegroundColor Green
}

# ============================================
# Step 3: Build connection string
# ============================================

Write-Host "Building connection string..." -ForegroundColor Yellow

if ($UseAccessToken) {
    # Use az CLI to get an access token for Azure SQL
    Write-Host "  Getting access token via az CLI..." -ForegroundColor Yellow
    $token = az account get-access-token --resource https://database.windows.net/ --query accessToken --output tsv 2>$null
    if ([string]::IsNullOrEmpty($token)) {
        Write-Host "  ERROR: Failed to get access token. Run 'az login' first." -ForegroundColor Red
        exit 1
    }
    # For DAB with access tokens, we use Entra ID auth in the connection string
    $connectionString = "Server=tcp:$SqlServer,1433;Database=$SqlDatabase;Authentication=Active Directory Default;Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;Command Timeout=120;"
    Write-Host "  Auth: Entra ID (Active Directory Default)" -ForegroundColor Green
} else {
    # SQL auth — prompt for password if not provided
    if ([string]::IsNullOrEmpty($SqlPassword)) {
        $securePassword = Read-Host "Enter SQL password for $SqlAdmin@$SqlServer" -AsSecureString
        $SqlPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        )
    }
    $connectionString = "Server=tcp:$SqlServer,1433;Database=$SqlDatabase;User ID=$SqlAdmin;Password=$SqlPassword;Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;"
    Write-Host "  Auth: SQL Authentication ($SqlAdmin)" -ForegroundColor Green
}

Write-Host "  Server: $SqlServer" -ForegroundColor White
Write-Host "  Database: $SqlDatabase" -ForegroundColor White

# ============================================
# Step 4: Set environment variable and start DAB
# ============================================

Write-Host ""
Write-Host "Starting SQL MCP Server locally..." -ForegroundColor Yellow
Write-Host "  Config:   $scriptDir\dab-config.json" -ForegroundColor White
Write-Host "  Health:   http://localhost:5000/health" -ForegroundColor White
Write-Host "  MCP:      http://localhost:5000/mcp" -ForegroundColor White
Write-Host ""
Write-Host "  Press Ctrl+C to stop." -ForegroundColor Gray
Write-Host ""

# Set the connection string environment variable that dab-config.json references
$env:MSSQL_CONNECTION_STRING = $connectionString

# Start DAB with the config file
Set-Location $scriptDir
dab start --config dab-config.json

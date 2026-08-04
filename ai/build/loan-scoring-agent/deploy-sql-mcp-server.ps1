# ============================================================
# deploy-sql-mcp-server.ps1
# Deploy ZavaFin Loan Scoring SQL MCP Server to Azure Container Apps
# Uses Managed Identity for database authentication (no SQL password)
#
# Prerequisites:
#   - Azure CLI installed (az login completed)
#   - Act 2 + Act 3 setup complete on <your-server>.database.windows.net
#   - Your Entra ID account must be SQL admin on the target server
#
# Usage:
#   .\deploy-sql-mcp-server.ps1
#   .\deploy-sql-mcp-server.ps1 -Location "westus2"
# ============================================================

param(
    [string]$ResourceGroup = "rg-zava-loan-mcp",
    [string]$Location = "eastus",
    [string]$SqlServer = "<your-server>",
    [string]$SqlDatabase = "zavalending"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ZavaFin Loan Scoring — SQL MCP Server" -ForegroundColor Cyan
Write-Host "  Deploy to Azure Container Apps" -ForegroundColor Cyan
Write-Host "  Auth: Managed Identity (Entra ID)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================
# Validate prerequisites
# ============================================

Write-Host "Checking prerequisites..." -ForegroundColor Yellow

try {
    $azVersion = az version 2>$null | ConvertFrom-Json
    Write-Host "  Azure CLI: $($azVersion.'azure-cli')" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Azure CLI not found. Install with: winget install Microsoft.AzureCLI" -ForegroundColor Red
    exit 1
}

# Check logged in
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  ERROR: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}
Write-Host "  Subscription: $($account.name)" -ForegroundColor Green

Write-Host ""

# ============================================
# Variables
# ============================================

$RANDOM_SUFFIX = Get-Random -Minimum 1000 -Maximum 9999
$ACR_NAME = "acrzavamcp$RANDOM_SUFFIX"
$CONTAINERAPP_ENV = "zava-mcp-env"
$CONTAINERAPP_NAME = "zava-loan-mcp"
# Managed Identity auth — no password needed
$CONNECTION_STRING = "Server=tcp:$SqlServer.database.windows.net,1433;Database=$SqlDatabase;Authentication=Active Directory Default;Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;Command Timeout=120;"

Write-Host "Deployment configuration:" -ForegroundColor Yellow
Write-Host "  Resource Group:    $ResourceGroup"
Write-Host "  Location:          $Location"
Write-Host "  SQL Server:        $SqlServer.database.windows.net"
Write-Host "  SQL Database:      $SqlDatabase"
Write-Host "  ACR Name:          $ACR_NAME"
Write-Host "  Container App:     $CONTAINERAPP_NAME"
Write-Host "  Auth:              Managed Identity (Entra ID)"
Write-Host ""

# ============================================
# Step 1: Create Resource Group
# ============================================

Write-Host "Step 1: Creating resource group..." -ForegroundColor Yellow

# Get current user alias for the required Owner tag
$currentUser = az ad signed-in-user show --query userPrincipalName --output tsv 2>$null
if ([string]::IsNullOrEmpty($currentUser)) {
    $currentUser = $account.user.name
}
$ownerAlias = $currentUser.Split('@')[0]
Write-Host "  Owner tag: $ownerAlias" -ForegroundColor White

az group create `
    --name $ResourceGroup `
    --location $Location `
    --tags "Owner=$ownerAlias" `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Failed to create resource group." -ForegroundColor Red
    exit 1
}
Write-Host "  Resource group '$ResourceGroup' ready." -ForegroundColor Green

# ============================================
# Step 2: Create Azure Container Registry
# ============================================

Write-Host "Step 2: Creating Azure Container Registry..." -ForegroundColor Yellow

az acr create `
    --resource-group $ResourceGroup `
    --name $ACR_NAME `
    --sku Basic `
    --admin-enabled true `
    --output none

if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Failed to create ACR." -ForegroundColor Red; exit 1 }
Write-Host "  ACR '$ACR_NAME' created." -ForegroundColor Green

# ============================================
# Step 3: Build and push Docker image
# ============================================

Write-Host "Step 3: Building and pushing Docker image..." -ForegroundColor Yellow

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

az acr build `
    --registry $ACR_NAME `
    --image zava-loan-mcp:1 `
    --platform linux/amd64 `
    $scriptDir

if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Failed to build/push image." -ForegroundColor Red; exit 1 }
Write-Host "  Image 'zava-loan-mcp:1' built and pushed." -ForegroundColor Green

# ============================================
# Step 4: Create Container Apps Environment
# ============================================

Write-Host "Step 4: Creating Container Apps environment..." -ForegroundColor Yellow

az containerapp env create `
    --name $CONTAINERAPP_ENV `
    --resource-group $ResourceGroup `
    --location $Location `
    --output none

if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Failed to create Container Apps environment." -ForegroundColor Red; exit 1 }
Write-Host "  Environment '$CONTAINERAPP_ENV' created." -ForegroundColor Green

# ============================================
# Step 5: Deploy the SQL MCP Server container
# ============================================

Write-Host "Step 5: Deploying SQL MCP Server container..." -ForegroundColor Yellow

$ACR_LOGIN_SERVER = az acr show --name $ACR_NAME --query loginServer --output tsv
$ACR_USERNAME = az acr credential show --name $ACR_NAME --query username --output tsv
$ACR_PASSWORD = az acr credential show --name $ACR_NAME --query "passwords[0].value" --output tsv

az containerapp create `
    --name $CONTAINERAPP_NAME `
    --resource-group $ResourceGroup `
    --environment $CONTAINERAPP_ENV `
    --image "$ACR_LOGIN_SERVER/zava-loan-mcp:1" `
    --registry-server $ACR_LOGIN_SERVER `
    --registry-username $ACR_USERNAME `
    --registry-password $ACR_PASSWORD `
    --target-port 5000 `
    --ingress external `
    --min-replicas 1 `
    --max-replicas 3 `
    --secrets "mssql-connection-string=$CONNECTION_STRING" `
    --env-vars "MSSQL_CONNECTION_STRING=secretref:mssql-connection-string" `
    --cpu 0.5 `
    --memory 1.0Gi `
    --output none

if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Failed to create container app." -ForegroundColor Red; exit 1 }
Write-Host "  Container app '$CONTAINERAPP_NAME' deployed." -ForegroundColor Green

# ============================================
# Step 6: Enable System-Assigned Managed Identity
# ============================================

Write-Host "Step 6: Enabling Managed Identity..." -ForegroundColor Yellow

$identityJson = az containerapp identity assign `
    --name $CONTAINERAPP_NAME `
    --resource-group $ResourceGroup `
    --system-assigned `
    --output json

$identity = $identityJson | ConvertFrom-Json
$principalId = $identity.principalId
Write-Host "  Managed Identity enabled. Principal ID: $principalId" -ForegroundColor Green

# ============================================
# Step 7: Grant SQL access to Managed Identity
# ============================================

Write-Host "Step 7: Granting SQL database access to Managed Identity..." -ForegroundColor Yellow

Write-Host "  Acquiring Azure access token..." -ForegroundColor Yellow
$sqlToken = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token | ConvertFrom-SecureString -AsPlainText
if (-not $sqlToken) {
    Write-Host "  ERROR: Could not acquire Azure access token. Run: Connect-AzAccount" -ForegroundColor Red
    exit 1
}

$sqlCmd = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$CONTAINERAPP_NAME')
    CREATE USER [$CONTAINERAPP_NAME] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$CONTAINERAPP_NAME];
ALTER ROLE db_datawriter ADD MEMBER [$CONTAINERAPP_NAME];
GRANT EXECUTE ON dbo.usp_ScoreLoanApplication TO [$CONTAINERAPP_NAME];
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [$CONTAINERAPP_NAME];
GRANT EXECUTE ON EXTERNAL MODEL::FoundryEmbeddingModel TO [$CONTAINERAPP_NAME];
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[https://<your-ai-account>.cognitiveservices.azure.com/] TO [$CONTAINERAPP_NAME];
PRINT 'Managed Identity SQL access granted.';
"@

Write-Host "  Running SQL grants..." -ForegroundColor Yellow
try {
    Invoke-Sqlcmd -ServerInstance "$SqlServer.database.windows.net" -Database $SqlDatabase -AccessToken $sqlToken -Query $sqlCmd -ErrorAction Stop
    Write-Host "  SQL access granted successfully." -ForegroundColor Green
} catch {
    Write-Host "  ERROR: SQL grants failed: $_" -ForegroundColor Red
    exit 1
}

# ============================================
# Step 8: Get MCP endpoint URL
# ============================================

Write-Host "Step 8: Retrieving MCP endpoint..." -ForegroundColor Yellow

$MCP_FQDN = az containerapp show `
    --name $CONTAINERAPP_NAME `
    --resource-group $ResourceGroup `
    --query "properties.configuration.ingress.fqdn" `
    --output tsv

$MCP_URL = "https://$MCP_FQDN/mcp"
$HEALTH_URL = "https://$MCP_FQDN/health"

# ============================================
# Step 9: Test health endpoint
# ============================================

Write-Host "Step 9: Testing health endpoint..." -ForegroundColor Yellow
Write-Host "  Waiting 15 seconds for container to start..." -ForegroundColor Gray
Start-Sleep -Seconds 15

$retries = 0
$healthy = $false
while ($retries -lt 6 -and -not $healthy) {
    try {
        $healthResponse = Invoke-RestMethod -Uri $HEALTH_URL -Method GET -TimeoutSec 30
        if ($healthResponse.status -eq "Healthy") {
            $healthy = $true
            Write-Host "  Health check: HEALTHY" -ForegroundColor Green
            Write-Host "  MCP enabled:  $($healthResponse.configuration.mcp)" -ForegroundColor Green
            Write-Host "  DB latency:   $($healthResponse.checks[0].data.'response-ms')ms" -ForegroundColor Green
        }
    } catch {
        $retries++
        Write-Host "  Attempt $retries/6 — Container starting... (waiting 10s)" -ForegroundColor Gray
        Start-Sleep -Seconds 10
    }
}

if (-not $healthy) {
    Write-Host "  Container may still be starting. Check manually:" -ForegroundColor Yellow
    Write-Host "  Invoke-RestMethod $HEALTH_URL" -ForegroundColor White
}

# ============================================
# Summary
# ============================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Deployment Complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  MCP Server URL:  $MCP_URL" -ForegroundColor Cyan
Write-Host "  Health Check:    $HEALTH_URL" -ForegroundColor Cyan
Write-Host "  Resource Group:  $ResourceGroup" -ForegroundColor White
Write-Host "  Container App:   $CONTAINERAPP_NAME" -ForegroundColor White
Write-Host "  Auth:            System-Assigned Managed Identity" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "  1. Verify health:  Invoke-RestMethod $HEALTH_URL" -ForegroundColor White
Write-Host "  2. Configure Foundry Agent: see foundry-agent-setup.md" -ForegroundColor White
Write-Host "  3. Use MCP URL as the remote endpoint in Foundry Agent" -ForegroundColor White
Write-Host ""
Write-Host "  To clean up:" -ForegroundColor Yellow
Write-Host "  az group delete --name $ResourceGroup --yes" -ForegroundColor White
Write-Host ""

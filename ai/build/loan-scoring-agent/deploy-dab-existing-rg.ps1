<#
.SYNOPSIS
    Deploy ZavaFin Loan Scoring SQL MCP Server to Azure Container Apps in <your-resource-group>.

.DESCRIPTION
    Deploys the DAB container with MCP endpoint to <your-resource-group> resource group
    under the <your-subscription> subscription. Uses managed identity for
    database auth.

    Target: <your-server>.database.windows.net / zavalending

.EXAMPLE
    .\deploy-dab-existing-rg.ps1
    .\deploy-dab-existing-rg.ps1 -Force   # Delete and recreate
#>

param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$subscriptionId   = '<your-subscription-id>'
$resourceGroup    = '<your-resource-group>'
$location         = 'eastus2'
$sqlServer        = '<your-server>'
$sqlDatabase      = 'zavalending'
$acrName          = 'zavafincr'
$envName          = 'zavafin-mcp-env'
$appName          = 'zavafin-loan-mcp'
$imageName        = 'zavafin-loan-mcp:1'
$scriptDir        = Split-Path -Parent $MyInvocation.MyCommand.Path

$connectionString = "Server=tcp:$sqlServer.database.windows.net,1433;Database=$sqlDatabase;Authentication=Active Directory Default;Encrypt=true;TrustServerCertificate=false;Connection Timeout=30;Command Timeout=120;"

$totalSteps = 8

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " ZavaFin SQL MCP Server — Deploy to <your-resource-group>"   -ForegroundColor Cyan
Write-Host " App:      $appName"                           -ForegroundColor Cyan
Write-Host " Server:   $sqlServer"                         -ForegroundColor Cyan
Write-Host " RG:       $resourceGroup"                     -ForegroundColor Cyan
Write-Host " Location: $location"                          -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Set subscription ──
Write-Host "[1/$totalSteps] Setting subscription..." -ForegroundColor Yellow
az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Run 'az login' first." -ForegroundColor Red; exit 1 }
Write-Host "  OK: <your-subscription>" -ForegroundColor Green
Write-Host ""

# ── Step 2: Force cleanup ──
if ($Force) {
    Write-Host "[2/$totalSteps] Cleaning up old deployment..." -ForegroundColor Yellow
    az containerapp delete --name $appName --resource-group $resourceGroup --yes --output none 2>$null
    az containerapp env delete --name $envName --resource-group $resourceGroup --yes --output none 2>$null
    az acr delete --name $acrName --resource-group $resourceGroup --yes --output none 2>$null
    Write-Host "  Cleaned up." -ForegroundColor Green
} else {
    Write-Host "[2/$totalSteps] Skipping cleanup (use -Force)." -ForegroundColor DarkGray
}
Write-Host ""

# ── Step 3: Create ACR ──
Write-Host "[3/$totalSteps] Creating Container Registry..." -ForegroundColor Yellow
$existingAcr = az acr show --name $acrName --resource-group $resourceGroup -o json 2>$null
if ($existingAcr) {
    Write-Host "  ACR already exists." -ForegroundColor Green
} else {
    az acr create --name $acrName --resource-group $resourceGroup --sku Basic --admin-enabled true --output none
    if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: ACR creation failed." -ForegroundColor Red; exit 1 }
    Write-Host "  ACR created: $acrName" -ForegroundColor Green
}
Write-Host ""

# ── Step 4: Build and push image ──
Write-Host "[4/$totalSteps] Building and pushing Docker image..." -ForegroundColor Yellow
az acr build --registry $acrName --image $imageName --platform linux/amd64 $scriptDir
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Image build failed." -ForegroundColor Red; exit 1 }
Write-Host "  Image pushed: $imageName" -ForegroundColor Green
Write-Host ""

# ── Step 5: Create Container Apps environment ──
Write-Host "[5/$totalSteps] Creating Container Apps environment..." -ForegroundColor Yellow
$existingEnv = az containerapp env show --name $envName --resource-group $resourceGroup -o json 2>$null
if ($existingEnv) {
    Write-Host "  Environment already exists." -ForegroundColor Green
} else {
    az containerapp env create --name $envName --resource-group $resourceGroup --location $location --output none
    if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Environment creation failed." -ForegroundColor Red; exit 1 }
    Write-Host "  Environment created: $envName" -ForegroundColor Green
}
Write-Host ""

# ── Step 6: Deploy container app ──
Write-Host "[6/$totalSteps] Deploying container app..." -ForegroundColor Yellow

$acrLoginServer = az acr show --name $acrName --query loginServer -o tsv
$acrUsername = az acr credential show --name $acrName --query username -o tsv
$acrPassword = az acr credential show --name $acrName --query "passwords[0].value" -o tsv

$existingApp = az containerapp show --name $appName --resource-group $resourceGroup -o json 2>$null
if ($existingApp) {
    Write-Host "  Updating existing app..." -ForegroundColor Gray
    az containerapp update --name $appName --resource-group $resourceGroup --image "$acrLoginServer/$imageName" --output none
} else {
    az containerapp create `
        --name $appName `
        --resource-group $resourceGroup `
        --environment $envName `
        --image "$acrLoginServer/$imageName" `
        --registry-server $acrLoginServer `
        --registry-username $acrUsername `
        --registry-password $acrPassword `
        --target-port 5000 `
        --ingress external `
        --min-replicas 1 `
        --max-replicas 3 `
        --secrets "mssql-conn=$connectionString" `
        --env-vars "MSSQL_CONNECTION_STRING=secretref:mssql-conn" `
        --cpu 0.5 `
        --memory 1.0Gi `
        --output none

    if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Container app creation failed." -ForegroundColor Red; exit 1 }
}
Write-Host "  Container app deployed." -ForegroundColor Green
Write-Host ""

# ── Step 7: Enable managed identity and grant SQL access ──
Write-Host "[7/$totalSteps] Enabling managed identity + SQL grants..." -ForegroundColor Yellow

az containerapp identity assign --name $appName --resource-group $resourceGroup --system-assigned --output none
$principalId = az containerapp identity show --name $appName --resource-group $resourceGroup --query "principalId" -o tsv
Write-Host "  Principal ID: $principalId" -ForegroundColor Green

# Grant SQL access
Write-Host "  Granting SQL permissions..." -ForegroundColor Gray
$sqlToken = (az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)

$sqlCmd = @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$appName')
    CREATE USER [$appName] FROM EXTERNAL PROVIDER;
ALTER ROLE db_datareader ADD MEMBER [$appName];
ALTER ROLE db_datawriter ADD MEMBER [$appName];
GRANT EXECUTE ON dbo.usp_ScoreLoanApplication TO [$appName];
GRANT EXECUTE ANY EXTERNAL ENDPOINT TO [$appName];
GRANT EXECUTE ON EXTERNAL MODEL::FoundryEmbeddingModel TO [$appName];
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[https://zavafin-ai-gateway.azure-api.net/] TO [$appName];
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::[https://<your-ai-account>.cognitiveservices.azure.com/] TO [$appName];
PRINT 'SQL permissions granted for $appName.';
"@

try {
    Invoke-Sqlcmd -ServerInstance "$sqlServer.database.windows.net" -Database $sqlDatabase -AccessToken $sqlToken -Query $sqlCmd -ErrorAction Stop
    Write-Host "  SQL access granted." -ForegroundColor Green
} catch {
    Write-Host "  WARNING: SQL grants may have failed: $_" -ForegroundColor Yellow
}
Write-Host ""

# ── Step 8: Get MCP endpoint ──
Write-Host "[8/$totalSteps] Getting MCP endpoint..." -ForegroundColor Yellow

$fqdn = az containerapp show --name $appName --resource-group $resourceGroup --query "properties.configuration.ingress.fqdn" -o tsv
$mcpUrl = "https://$fqdn/mcp"
$healthUrl = "https://$fqdn/health"

Write-Host "  MCP Endpoint: $mcpUrl" -ForegroundColor Green
Write-Host "  Health:       $healthUrl" -ForegroundColor Green
Write-Host ""

# Save config
$configFile = Join-Path $scriptDir "mcp-endpoint.json"
@{
    mcpUrl    = $mcpUrl
    healthUrl = $healthUrl
    appName   = $appName
    fqdn      = $fqdn
} | ConvertTo-Json | Out-File -FilePath $configFile -Encoding utf8 -Force
Write-Host "  Config saved: $configFile" -ForegroundColor Gray

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " SQL MCP Server Ready"                         -ForegroundColor Green
Write-Host " MCP: $mcpUrl"                                 -ForegroundColor White
Write-Host ""
Write-Host " Next: Create a Foundry agent and connect"     -ForegroundColor Yellow
Write-Host "       this MCP endpoint as a custom tool."    -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Green

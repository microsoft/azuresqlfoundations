# ============================================================
# deploy-foundry-agent.ps1
# Create a Foundry project and deploy a Loan Scoring Agent
# with MCP tool connected to the SQL MCP Server on Container Apps
#
# Prerequisites:
#   - Azure CLI installed (az login completed)
#   - SQL MCP Server deployed (run deploy-sql-mcp-server.ps1 first)
#   - Container App healthy at the MCP endpoint URL
#
# Usage:
#   .\deploy-foundry-agent.ps1
#   .\deploy-foundry-agent.ps1 -McpEndpoint "https://my-app.azurecontainerapps.io/mcp"
#
# What this script does:
#   1. Enables project management on the <your-ai-account> AIServices resource
#   2. Creates a Foundry project (zava-loan-agent)
#   3. Deploys a chat model (gpt-4.1-mini) for agent reasoning
#   4. Creates the Loan Scoring Agent with MCP tool via REST API
#   5. Tests the agent with a sample query
# ============================================================

param(
    [string]$FoundryResource = "<your-ai-account>",
    [string]$FoundryResourceGroup = "<your-resource-group>",
    [string]$ProjectName = "zava-loan-agent",
    [string]$Location = "eastus2",
    [string]$ModelName = "gpt-4.1",
    [string]$ModelVersion = "2025-04-14",
    [string]$McpEndpoint = "https://<your-app>.<region>.azurecontainerapps.io/mcp",
    [string]$AgentName = "ZavaFinLoanScoringAgent"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ZavaFin Loan Scoring — Foundry Agent" -ForegroundColor Cyan
Write-Host "  Create Project + Deploy Agent + MCP Tool" -ForegroundColor Cyan
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

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  ERROR: Not logged in. Run 'az login' first." -ForegroundColor Red
    exit 1
}
Write-Host "  Subscription: $($account.name)" -ForegroundColor Green
Write-Host "  Subscription ID: $($account.id)" -ForegroundColor Green

# Verify MCP server is healthy
Write-Host ""
Write-Host "Verifying MCP server health..." -ForegroundColor Yellow
$healthUrl = $McpEndpoint -replace '/mcp$', '/health'
try {
    $health = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 10
    Write-Host "  MCP Server: Healthy" -ForegroundColor Green
    Write-Host "  Database: $($health.database.status)" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not reach MCP server at $healthUrl" -ForegroundColor Red
    Write-Host "  Make sure deploy-sql-mcp-server.ps1 has been run first." -ForegroundColor Red
    $continue = Read-Host "  Continue anyway? (y/N)"
    if ($continue -ne 'y') { exit 1 }
}

# ============================================
# Step 1: Enable project management on Foundry resource
# ============================================

Write-Host ""
Write-Host "Step 1: Enabling project management on $FoundryResource..." -ForegroundColor Yellow

# Check if the resource exists
$resource = az cognitiveservices account show `
    --name $FoundryResource `
    --resource-group $FoundryResourceGroup 2>$null | ConvertFrom-Json

if (-not $resource) {
    Write-Host "  ERROR: Foundry resource '$FoundryResource' not found in '$FoundryResourceGroup'" -ForegroundColor Red
    exit 1
}
Write-Host "  Resource found: $($resource.name) ($($resource.kind), $($resource.location))" -ForegroundColor Green
Write-Host "  Endpoint: $($resource.properties.endpoint)" -ForegroundColor Green

# Enable project management via REST API PUT (requires identity + preview API)
# The --allow-project-management CLI flag requires CLI 2.67+, and PATCH doesn't persist.
# Must use full PUT with identity.type=SystemAssigned on the preview API version.
$subscriptionId = $account.id
$mgmtApiVersion = "2025-04-01-preview"
$resourceUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$FoundryResourceGroup/providers/Microsoft.CognitiveServices/accounts/${FoundryResource}?api-version=$mgmtApiVersion"

$customDomain = $resource.properties.customSubDomainName
if (-not $customDomain) { $customDomain = $FoundryResource }

$updateJson = '{"location":"' + $resource.location + '","kind":"' + $resource.kind + '","sku":{"name":"' + $resource.sku.name + '"},"identity":{"type":"SystemAssigned"},"properties":{"allowProjectManagement":true,"customSubDomainName":"' + $customDomain + '","publicNetworkAccess":"Enabled"}}'
$tempFile = Join-Path $env:TEMP "foundry-update.json"
[System.IO.File]::WriteAllText($tempFile, $updateJson)

$putResult = az rest --method PUT --url $resourceUri --body "@$tempFile" --headers "Content-Type=application/json" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR enabling project management: $putResult" -ForegroundColor Red
    exit 1
}
$putObj = $putResult | ConvertFrom-Json
Write-Host "  allowProjectManagement = $($putObj.properties.allowProjectManagement)" -ForegroundColor Green

# ============================================
# Step 2: Create the Foundry project
# ============================================

Write-Host ""
Write-Host "Step 2: Creating Foundry project '$ProjectName'..." -ForegroundColor Yellow

# Use Azure REST API directly (az cognitiveservices account project requires CLI 2.67+)
$projectResourceId = "/subscriptions/$subscriptionId/resourceGroups/$FoundryResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryResource/projects/$ProjectName"
$projectUri = "https://management.azure.com${projectResourceId}?api-version=$mgmtApiVersion"

# Check if project already exists
$existingProject = $null
try {
    $existingProject = az rest --method GET --url $projectUri 2>$null | ConvertFrom-Json
} catch { }

if ($existingProject -and $existingProject.name) {
    Write-Host "  Project already exists: $($existingProject.name)" -ForegroundColor Green
} else {
    $projectJson = '{"location":"' + $Location + '","identity":{"type":"SystemAssigned"},"properties":{}}'
    $tempProjectFile = Join-Path $env:TEMP "foundry-project.json"
    [System.IO.File]::WriteAllText($tempProjectFile, $projectJson)
    $putResult = az rest --method PUT --url $projectUri --body "@$tempProjectFile" --headers "Content-Type=application/json" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR creating project: $putResult" -ForegroundColor Red
        exit 1
    }
    $existingProject = $putResult | ConvertFrom-Json
    Write-Host "  Project created: $($existingProject.name)" -ForegroundColor Green
}

# Extract project endpoint
# Format: https://<resource>.services.ai.azure.com/api/projects/<project-name>
$foundryEndpoint = $resource.properties.endpoint.TrimEnd('/')
if ($foundryEndpoint -match '\.cognitiveservices\.azure\.com') {
    # Convert to services endpoint format
    $projectEndpoint = $foundryEndpoint -replace '\.cognitiveservices\.azure\.com', '.services.ai.azure.com'
    $projectEndpoint = "$projectEndpoint/api/projects/$ProjectName"
} elseif ($foundryEndpoint -match '\.services\.ai\.azure\.com') {
    $projectEndpoint = "$foundryEndpoint/api/projects/$ProjectName"
} else {
    # Construct from resource name
    $projectEndpoint = "https://$FoundryResource.services.ai.azure.com/api/projects/$ProjectName"
}

Write-Host "  Project endpoint: $projectEndpoint" -ForegroundColor Green

# ============================================
# Step 3: Deploy chat model for agent reasoning
# ============================================

Write-Host ""
Write-Host "Step 3: Deploying model '$ModelName' for agent reasoning..." -ForegroundColor Yellow

# Check if model already deployed
$existingDeployment = az cognitiveservices account deployment show `
    --name $FoundryResource `
    --resource-group $FoundryResourceGroup `
    --deployment-name $ModelName 2>$null | ConvertFrom-Json

if ($existingDeployment) {
    Write-Host "  Model already deployed: $($existingDeployment.name)" -ForegroundColor Green
    Write-Host "  Status: $($existingDeployment.properties.provisioningState)" -ForegroundColor Green
} else {
    Write-Host "  Deploying $ModelName (this may take a minute)..." -ForegroundColor Yellow

    az cognitiveservices account deployment create `
        --name $FoundryResource `
        --resource-group $FoundryResourceGroup `
        --deployment-name $ModelName `
        --model-name $ModelName `
        --model-version $ModelVersion `
        --model-format OpenAI `
        --sku-capacity 10 `
        --sku-name Standard

    $existingDeployment = az cognitiveservices account deployment show `
        --name $FoundryResource `
        --resource-group $FoundryResourceGroup `
        --deployment-name $ModelName | ConvertFrom-Json

    Write-Host "  Model deployed: $($existingDeployment.name)" -ForegroundColor Green
    Write-Host "  Status: $($existingDeployment.properties.provisioningState)" -ForegroundColor Green
}

# ============================================
# Step 4: Create the Loan Scoring Agent with MCP Tool
# ============================================

Write-Host ""
Write-Host "Step 4: Creating Loan Scoring Agent with MCP tool..." -ForegroundColor Yellow

# Get access token for Foundry API
$token = az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv

$headers = @{
    "Content-Type" = "application/json"
    "Authorization" = "Bearer $token"
}

# Check if agent already exists
$agentExists = $false
try {
    $existingAgent = Invoke-RestMethod `
        -Uri "$projectEndpoint/agents/$AgentName`?api-version=v1" `
        -Method Get `
        -Headers $headers
    if ($existingAgent -and $existingAgent.id) {
        $agentExists = $true
        Write-Host "  Agent already exists: $($existingAgent.name) (version $($existingAgent.version))" -ForegroundColor Green
    }
} catch { }

if (-not $agentExists) {
    # Read agent instructions from file
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $instructionsFile = Join-Path $scriptDir "agent-instructions.txt"

    if (Test-Path $instructionsFile) {
        $instructions = Get-Content $instructionsFile -Raw
        Write-Host "  Loaded instructions from agent-instructions.txt" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: agent-instructions.txt not found, using default instructions" -ForegroundColor Red
        $instructions = "You are a loan scoring agent. Use the MCP tools to query and score loan applications."
    }

    # Create agent via REST API
    $agentBody = @{
        name = $AgentName
        description = "ZavaFin AI-powered loan underwriting agent with SQL MCP Server for vector search and Phi-4 risk assessment"
        definition = @{
            kind = "prompt"
            model = $ModelName
            instructions = $instructions
            tools = @(
                @{
                    type = "mcp"
                    server_label = "zava-loan-scoring-mcp"
                    server_url = $McpEndpoint
                    require_approval = "never"
                }
            )
        }
    } | ConvertTo-Json -Depth 10

    try {
        $agentResponse = Invoke-RestMethod `
            -Uri "$projectEndpoint/agents?api-version=v1" `
            -Method Post `
            -Headers $headers `
            -Body $agentBody

        Write-Host "  Agent created!" -ForegroundColor Green
        Write-Host "  Name: $($agentResponse.name)" -ForegroundColor Green
        Write-Host "  ID: $($agentResponse.id)" -ForegroundColor Green
        Write-Host "  Version: $($agentResponse.version)" -ForegroundColor Green
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody = $_.ErrorDetails.Message
        Write-Host "  ERROR creating agent (HTTP $statusCode): $errorBody" -ForegroundColor Red
        exit 1
    }
}

# ============================================
# Step 5: Test the agent
# ============================================

Write-Host ""
Write-Host "Step 5: Testing agent with sample query..." -ForegroundColor Yellow

# Refresh token (in case the previous steps took a while)
$token = az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv
$headers = @{
    "Content-Type" = "application/json"
    "Authorization" = "Bearer $token"
}

$testBody = @{
    agent_reference = @{
        type = "agent_reference"
        name = $AgentName
    }
    input = "What entities are available in the loan scoring database? Use describe_entities to find out."
} | ConvertTo-Json -Depth 5

try {
    Write-Host "  Sending: 'What entities are available in the loan scoring database?'" -ForegroundColor Yellow
    $testResponse = Invoke-RestMethod `
        -Uri "$projectEndpoint/openai/v1/responses" `
        -Method Post `
        -Headers $headers `
        -Body $testBody `
        -TimeoutSec 120

    Write-Host ""
    Write-Host "  Agent response:" -ForegroundColor Green
    # Extract text from the last message output
    $outputText = $testResponse.output_text
    if (-not $outputText) {
        $lastMsg = $testResponse.output | Where-Object { $_.type -eq "message" } | Select-Object -Last 1
        if ($lastMsg -and $lastMsg.content) {
            $outputText = ($lastMsg.content | Where-Object { $_.type -eq "output_text" }).text
        }
    }
    if ($outputText) {
        Write-Host "  $outputText" -ForegroundColor White
    } else {
        Write-Host "  (Response received but no text output found)" -ForegroundColor Yellow
        Write-Host "  Status: $($testResponse.status)" -ForegroundColor Yellow
    }
    Write-Host ""
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody = $_.ErrorDetails.Message
    Write-Host "  ERROR testing agent (HTTP $statusCode): $errorBody" -ForegroundColor Red
    Write-Host "  You can test manually in the Foundry portal at https://ai.azure.com" -ForegroundColor Yellow
}

# ============================================
# Summary
# ============================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "  Foundry Agent Deployment Complete" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Foundry Resource:  $FoundryResource" -ForegroundColor White
Write-Host "  Project:           $ProjectName" -ForegroundColor White
Write-Host "  Model:             $ModelName" -ForegroundColor White
Write-Host "  Agent:             $AgentName" -ForegroundColor White
Write-Host "  MCP Endpoint:      $McpEndpoint" -ForegroundColor White
Write-Host "  Project Endpoint:  $projectEndpoint" -ForegroundColor White
Write-Host ""
Write-Host "  Portal:  https://ai.azure.com" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Test prompts to try in the playground:" -ForegroundColor Yellow
Write-Host "    1. 'What entities are available in the loan scoring database?'" -ForegroundColor White
Write-Host "    2. 'Show me all pending loan applications'" -ForegroundColor White
Write-Host "    3. 'Score loan application #1'" -ForegroundColor White
Write-Host "    4. 'Show me the scoring decision for application #1'" -ForegroundColor White
Write-Host ""

# ============================================
# Clean up helper
# ============================================

Write-Host "  To delete the agent:" -ForegroundColor DarkGray
Write-Host "    `$token = az account get-access-token --scope 'https://ai.azure.com/.default' --query accessToken -o tsv" -ForegroundColor DarkGray
Write-Host "    Invoke-RestMethod -Uri '$projectEndpoint/agents/$AgentName`?api-version=v1' -Method Delete -Headers @{Authorization=`"Bearer `$token`"}" -ForegroundColor DarkGray
Write-Host ""

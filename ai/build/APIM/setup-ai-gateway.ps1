<#
.SYNOPSIS
    Deploy and configure Azure API Management AI Gateway for ZavaFin loan scoring.

.DESCRIPTION
    Creates an APIM StandardV2 instance as an AI Gateway in front of Phi-4,
    with managed identity auth, token rate limiting, and token metrics.

    Uses REST API throughout (az apim backend/subscription/policy subcommands
    aren't available in all CLI versions).

    Idempotent — safe to re-run. Each step checks if the resource already exists.

    After deployment, run 10-ai-gateway-switch.sql to point the database
    at the gateway.

    Components created:
      - APIM StandardV2 instance (zavafin-ai-gateway)
      - System-assigned managed identity with Cognitive Services User role
      - Phi-4 backend pointing to <your-ai-account>
      - Azure OpenAI API with chat completions operation
      - Policies: managed identity auth, 10K TPM rate limit, token metrics

.PARAMETER Force
    Delete and recreate the APIM instance from scratch.

.EXAMPLE
    .\setup-ai-gateway.ps1
    .\setup-ai-gateway.ps1 -Force
#>

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Configuration ──
$subscriptionId = '<your-subscription-id>'
$resourceGroup  = '<your-resource-group>'
$location       = 'eastus2'
$apimName       = 'zavafin-ai-gateway'
$aiResourceName = '<your-ai-account>'
$backendId      = 'phi4-backend'
$apiId          = 'azure-openai-api'
$apiVersion     = '2024-06-01-preview'
$baseUrl        = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName"

function Invoke-ApimRest {
    param([string]$Method, [string]$Path, [hashtable]$Body = $null, [switch]$OutputFile)
    $url = "$baseUrl/$Path`?api-version=$apiVersion"
    if ($Body) {
        $bodyJson = $Body | ConvertTo-Json -Depth 10 -Compress
        $bodyFile = Join-Path $env:TEMP "apim-rest-body.json"
        # Write without BOM — az rest chokes on BOM in responses with policy XML
        [System.IO.File]::WriteAllText($bodyFile, $bodyJson, [System.Text.UTF8Encoding]::new($false))
        if ($OutputFile) {
            $outFile = Join-Path $env:TEMP "apim-rest-out.json"
            az rest --method $Method --url $url --body "@$bodyFile" --output-file $outFile 2>$null
            $result = [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
        } else {
            $result = az rest --method $Method --url $url --body "@$bodyFile" 2>&1
        }
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    } else {
        if ($OutputFile) {
            $outFile = Join-Path $env:TEMP "apim-rest-out.json"
            az rest --method $Method --url $url --output-file $outFile 2>$null
            $result = [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
        } else {
            $result = az rest --method $Method --url $url 2>&1
        }
    }
    return $result
}

$totalSteps = 8

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " ZavaFin AI Gateway Setup"                     -ForegroundColor Cyan
Write-Host " APIM:     $apimName (StandardV2)"             -ForegroundColor Cyan
Write-Host " Backend:  $aiResourceName (Phi-4)"            -ForegroundColor Cyan
Write-Host " Region:   $location"                          -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Set subscription ──
Write-Host "[1/$totalSteps] Setting subscription..." -ForegroundColor Yellow
az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: Run 'az login' first." -ForegroundColor Red; exit 1 }
Write-Host "  OK" -ForegroundColor Green
Write-Host ""

# ── Step 2: Register provider ──
Write-Host "[2/$totalSteps] Checking Microsoft.ApiManagement provider..." -ForegroundColor Yellow
$provState = az provider show --namespace Microsoft.ApiManagement --query "registrationState" -o tsv 2>$null
if ($provState -ne 'Registered') {
    Write-Host "  Registering provider..." -ForegroundColor Gray
    az provider register --namespace Microsoft.ApiManagement --output none
    do {
        Start-Sleep -Seconds 10
        $provState = az provider show --namespace Microsoft.ApiManagement --query "registrationState" -o tsv
        Write-Host "  State: $provState"
    } while ($provState -ne 'Registered')
}
Write-Host "  Registered" -ForegroundColor Green
Write-Host ""

# ── Step 3: Create APIM instance ──
Write-Host "[3/$totalSteps] Creating APIM instance..." -ForegroundColor Yellow

if ($Force) {
    Write-Host "  Force cleanup..." -ForegroundColor Gray
    az rest --method DELETE --url "$baseUrl`?api-version=$apiVersion" --output none 2>$null
    Start-Sleep -Seconds 10
}

# Check if exists
$existing = az rest --method GET --url "$baseUrl`?api-version=$apiVersion" --query "properties.provisioningState" -o tsv 2>$null
if ($existing -eq 'Succeeded') {
    Write-Host "  Already exists and ready." -ForegroundColor Green
} else {
    # Create via REST API (StandardV2 not supported by az apim create)
    $createBody = @{
        location = $location
        sku = @{ name = "StandardV2"; capacity = 1 }
        identity = @{ type = "SystemAssigned" }
        properties = @{
            publisherEmail = "<your-email>"
            publisherName = "ZavaFin"
        }
    }
    $bodyJson = $createBody | ConvertTo-Json -Depth 5 -Compress
    $bodyFile = Join-Path $env:TEMP "apim-create.json"
    [System.IO.File]::WriteAllText($bodyFile, $bodyJson, [System.Text.UTF8Encoding]::new($false))

    az rest --method PUT --url "$baseUrl`?api-version=$apiVersion" --body "@$bodyFile" --output none
    Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: APIM creation failed." -ForegroundColor Red; exit 1 }

    # Wait for provisioning
    Write-Host "  Waiting for provisioning..." -ForegroundColor Gray
    do {
        Start-Sleep -Seconds 15
        $state = az rest --method GET --url "$baseUrl`?api-version=$apiVersion" --query "properties.provisioningState" -o tsv 2>$null
        Write-Host "  State: $state"
    } while ($state -ne 'Succeeded' -and $state -ne 'Failed')

    if ($state -ne 'Succeeded') { Write-Host "  ERROR: Provisioning $state" -ForegroundColor Red; exit 1 }
    Write-Host "  Created." -ForegroundColor Green
}
Write-Host ""

# ── Step 4: Get gateway URL and principal ID ──
Write-Host "[4/$totalSteps] Getting gateway details..." -ForegroundColor Yellow
$apimInfo = az rest --method GET --url "$baseUrl`?api-version=$apiVersion" --query "{gatewayUrl:properties.gatewayUrl, principalId:identity.principalId}" -o json | ConvertFrom-Json
$gatewayUrl = $apimInfo.gatewayUrl
$principalId = $apimInfo.principalId
Write-Host "  Gateway:    $gatewayUrl" -ForegroundColor Green
Write-Host "  Principal:  $principalId" -ForegroundColor Green
Write-Host ""

# ── Step 5: Grant RBAC ──
Write-Host "[5/$totalSteps] Granting Cognitive Services User role..." -ForegroundColor Yellow
$aiResourceId = az cognitiveservices account show --name $aiResourceName --resource-group $resourceGroup --query "id" -o tsv
$existingRole = az role assignment list --assignee $principalId --scope $aiResourceId --role "Cognitive Services User" --query "[0].id" -o tsv 2>$null
if ($existingRole) {
    Write-Host "  Already assigned." -ForegroundColor Green
} else {
    az role assignment create --assignee $principalId --role "Cognitive Services User" --scope $aiResourceId --output none
    if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR" -ForegroundColor Red; exit 1 }
    Write-Host "  Assigned." -ForegroundColor Green
}
Write-Host ""

# ── Step 6: Create backend ──
Write-Host "[6/$totalSteps] Creating Phi-4 backend..." -ForegroundColor Yellow
$backendUrl = "https://${aiResourceName}.cognitiveservices.azure.com/openai"
$result = Invoke-ApimRest -Method PUT -Path "backends/$backendId" -Body @{
    properties = @{ url = $backendUrl; protocol = "http"; description = "Azure AI Services - Phi-4" }
}
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR: $result" -ForegroundColor Red; exit 1 }
Write-Host "  Backend: $backendUrl" -ForegroundColor Green
Write-Host ""

# ── Step 7: Create API + operation + policies ──
Write-Host "[7/$totalSteps] Creating API, operation, and policies..." -ForegroundColor Yellow

# Create API
$result = Invoke-ApimRest -Method PUT -Path "apis/$apiId" -Body @{
    properties = @{
        displayName = "Azure OpenAI - ZavaFin"
        path = "openai"
        protocols = @("https")
        serviceUrl = $backendUrl
        subscriptionRequired = $true
        subscriptionKeyParameterNames = @{
            header = "Ocp-Apim-Subscription-Key"
            query = "subscription-key"
        }
    }
}
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR creating API" -ForegroundColor Red; exit 1 }
Write-Host "  API created." -ForegroundColor Green

# Create operation
$result = Invoke-ApimRest -Method PUT -Path "apis/$apiId/operations/chat-completions" -Body @{
    properties = @{
        displayName = "Chat Completions"
        method = "POST"
        urlTemplate = "/deployments/{deployment-id}/chat/completions"
        templateParameters = @(
            @{ name = "deployment-id"; required = $true; type = "string"; description = "Model deployment name" }
        )
    }
}
Write-Host "  Operation created." -ForegroundColor Green

# Apply policies (use -OutputFile to avoid BOM encoding crash in az rest)
$policyXml = '<policies><inbound><base /><set-backend-service backend-id="phi4-backend" /><authentication-managed-identity resource="https://cognitiveservices.azure.com" /><azure-openai-token-limit tokens-per-minute="10000" counter-key="@(context.Subscription.Id)" estimate-prompt-tokens="true" tokens-consumed-header-name="x-tokens-consumed" remaining-tokens-header-name="x-tokens-remaining" /><azure-openai-emit-token-metric namespace="zavafin-ai-gateway"><dimension name="Subscription" value="@(context.Subscription.Id)" /><dimension name="API" value="@(context.Api.Name)" /><dimension name="Deployment" value="Phi-4" /><dimension name="Operation" value="LoanScoring" /></azure-openai-emit-token-metric></inbound><backend><forward-request timeout="120" /></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

$result = Invoke-ApimRest -Method PUT -Path "apis/$apiId/policies/policy" -Body @{
    properties = @{ format = "xml"; value = $policyXml }
} -OutputFile
Write-Host "  Policies applied: managed identity, 10K TPM limit, token metrics" -ForegroundColor Green
Write-Host ""

# ── Step 8: Get subscription key ──
Write-Host "[8/$totalSteps] Retrieving subscription key..." -ForegroundColor Yellow
$subsResult = Invoke-ApimRest -Method GET -Path "subscriptions"
$subs = ($subsResult | Out-String | ConvertFrom-Json).value
$builtIn = $subs | Where-Object { $_.properties.displayName -like '*Built*' -or $_.name -eq 'master' } | Select-Object -First 1
if (-not $builtIn) { $builtIn = $subs | Select-Object -First 1 }

if ($builtIn) {
    $subName = $builtIn.name
    $keysResult = Invoke-ApimRest -Method POST -Path "subscriptions/$subName/listSecrets"
    $keys = $keysResult | Out-String | ConvertFrom-Json

    if ($keys.primaryKey) {
        Write-Host "  Subscription Key: $($keys.primaryKey)" -ForegroundColor Green

        # Save config files
        $configFile = Join-Path $PSScriptRoot "apim-config.json"
        @{
            gatewayUrl      = $gatewayUrl
            gatewayHost     = ($gatewayUrl -replace 'https://', '') -replace '/$', ''
            apimName        = $apimName
            subscriptionKey = $keys.primaryKey
        } | ConvertTo-Json | Out-File -FilePath $configFile -Encoding utf8 -Force
        Write-Host "  Config: $configFile" -ForegroundColor Gray

        $keys.primaryKey | Out-File -FilePath (Join-Path $PSScriptRoot "apim-key.txt") -Encoding utf8 -NoNewline -Force
        Write-Host "  Key:    apim-key.txt" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " AI Gateway Ready"                             -ForegroundColor Green
Write-Host " $gatewayUrl"                                  -ForegroundColor White
Write-Host ""
Write-Host " Policies:"                                    -ForegroundColor White
Write-Host "   Managed identity auth (no API key in transit)" -ForegroundColor Gray
Write-Host "   Token rate limiting (10K TPM)"              -ForegroundColor Gray
Write-Host "   Token metrics (Azure Monitor)"              -ForegroundColor Gray
Write-Host ""
Write-Host " Next: Run 10-ai-gateway-switch.sql"           -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Green

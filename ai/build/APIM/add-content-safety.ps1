# Add content safety backend and update policy
$ErrorActionPreference = 'Stop'

$subscriptionId = '<your-subscription-id>'
$resourceGroup  = '<your-resource-group>'
$apimName       = 'zavafin-ai-gateway'
$aiResourceName = '<your-ai-account>'
$apiId          = 'azure-openai-api'
$apiVersion     = '2024-06-01-preview'
$baseUrl        = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName"

function Invoke-ApimRest {
    param([string]$Method, [string]$Path, [hashtable]$Body = $null)
    $url = "$baseUrl/$Path`?api-version=$apiVersion"
    if ($Body) {
        $bodyJson = $Body | ConvertTo-Json -Depth 10 -Compress
        $bodyFile = Join-Path $env:TEMP "apim-rest-body.json"
        [System.IO.File]::WriteAllText($bodyFile, $bodyJson, [System.Text.UTF8Encoding]::new($false))
        $outFile = Join-Path $env:TEMP "apim-rest-out.json"
        az rest --method $Method --url $url --body "@$bodyFile" --output-file $outFile 2>$null
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    } else {
        az rest --method $Method --url $url --output none 2>$null
    }
}

Write-Host "=== Adding Content Safety to AI Gateway ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Create content safety backend
Write-Host "[1/2] Creating content safety backend..." -ForegroundColor Yellow
$csUrl = "https://${aiResourceName}.cognitiveservices.azure.com"
Invoke-ApimRest -Method PUT -Path "backends/contentsafety-backend" -Body @{
    properties = @{ url = $csUrl; protocol = "http"; description = "Azure AI Content Safety" }
}
if ($LASTEXITCODE -ne 0) { Write-Host "  ERROR" -ForegroundColor Red; exit 1 }
Write-Host "  Backend: $csUrl" -ForegroundColor Green
Write-Host ""

# Step 2: Update policy to include content safety
Write-Host "[2/2] Updating policy with content safety..." -ForegroundColor Yellow

$policyXml = '<policies><inbound><base /><set-backend-service backend-id="phi4-backend" /><authentication-managed-identity resource="https://cognitiveservices.azure.com" /><azure-openai-token-limit tokens-per-minute="10000" counter-key="@(context.Subscription.Id)" estimate-prompt-tokens="true" tokens-consumed-header-name="x-tokens-consumed" remaining-tokens-header-name="x-tokens-remaining" /><llm-content-safety backend-id="contentsafety-backend"><category name="Hate" threshold="2" /><category name="Sexual" threshold="2" /><category name="SelfHarm" threshold="2" /><category name="Violence" threshold="2" /></llm-content-safety><azure-openai-emit-token-metric namespace="zavafin-ai-gateway"><dimension name="Subscription" value="@(context.Subscription.Id)" /><dimension name="API" value="@(context.Api.Name)" /><dimension name="Deployment" value="Phi-4" /><dimension name="Operation" value="LoanScoring" /></azure-openai-emit-token-metric></inbound><backend><forward-request timeout="120" /></backend><outbound><base /></outbound><on-error><base /><choose><when condition="@(context.LastError.Source == &quot;llm-content-safety&quot;)"><return-response><set-status code="400" reason="Content Filtered" /><set-header name="Content-Type" exists-action="override"><value>application/json</value></set-header><set-body>{"error": {"code": "content_safety", "message": "ZavaFin AI Gateway: Request blocked by content safety policy. The loan scoring request contained content that violated safety guidelines."}}</set-body></return-response></when></choose></on-error></policies>'

Invoke-ApimRest -Method PUT -Path "apis/$apiId/policies/policy" -Body @{
    properties = @{ format = "xml"; value = $policyXml }
}
if ($LASTEXITCODE -ne 0) { Write-Host "  WARNING: Check portal" -ForegroundColor Yellow }
else { Write-Host "  Policy updated with content safety (threshold=2)" -ForegroundColor Green }

Write-Host ""
Write-Host "=== Content Safety Active ===" -ForegroundColor Green
Write-Host "  Categories: Hate, Sexual, SelfHarm, Violence (threshold 2 = strict)" -ForegroundColor Gray
Write-Host "  Blocked requests return HTTP 400 with content_safety error code" -ForegroundColor Gray

# Rebuilds APIM sub-resources on the fresh zavafin-ai-gateway: API, operation, backends, policy.
$ErrorActionPreference = 'Stop'
$subId = '<your-subscription-id>'
$g = '<your-resource-group>'; $s = 'zavafin-ai-gateway'; $api = 'azure-openai-api'
$ver = '2024-05-01'
$base = "https://management.azure.com/subscriptions/$subId/resourceGroups/$g/providers/Microsoft.ApiManagement/service/$s"
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$h = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
function Put($path, $obj) {
    $uri = "$base/$path" + "?api-version=$ver"
    $body = $obj | ConvertTo-Json -Depth 10
    $r = Invoke-WebRequest -Uri $uri -Headers $h -Method Put -Body $body
    Write-Host ("PUT {0} -> {1}" -f $path, $r.StatusCode)
}

# 1. API
Put "apis/$api" @{ properties = @{
    displayName = 'Azure OpenAI - ZavaFin'
    path = 'openai'
    serviceUrl = 'https://<your-ai-account>.cognitiveservices.azure.com/openai'
    protocols = @('https')
    subscriptionRequired = $true
    subscriptionKeyParameterNames = @{ header = 'Ocp-Apim-Subscription-Key'; query = 'subscription-key' }
} }

# 2. Operation
Put "apis/$api/operations/chat-completions" @{ properties = @{
    displayName = 'Chat Completions'
    method = 'POST'
    urlTemplate = '/deployments/{deployment-id}/chat/completions'
    templateParameters = @(@{ name = 'deployment-id'; type = 'string'; required = $true; description = 'Model deployment name' })
} }

# 3. Backends
Put "backends/phi4-backend" @{ properties = @{
    description = 'Azure AI Services - Phi-4'
    url = 'https://<your-ai-account>.cognitiveservices.azure.com/openai'
    protocol = 'http'
} }
Put "backends/contentsafety-backend" @{ properties = @{
    url = 'https://<your-ai-account>.cognitiveservices.azure.com'
    protocol = 'http'
} }

# 4. API policy (original MI-based design)
$xml = Get-Content -Raw (Join-Path $PSScriptRoot 'original-api-policy.xml')
Put "apis/$api/policies/policy" @{ properties = @{ format = 'rawxml'; value = $xml } }

Write-Host '=== REBUILD CONFIG COMPLETE ==='
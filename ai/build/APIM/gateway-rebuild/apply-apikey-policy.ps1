param([Parameter(Mandatory=$true)][string]$AiKey)
$ErrorActionPreference = 'Stop'
$subId = '<your-subscription-id>'
$g = '<your-resource-group>'; $s = 'zavafin-ai-gateway'; $api = 'azure-openai-api'; $ver = '2024-05-01'
$base = "https://management.azure.com/subscriptions/$subId/resourceGroups/$g/providers/Microsoft.ApiManagement/service/$s"
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$h = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
function Put($path, $obj) {
    $uri = "$base/$path" + "?api-version=$ver"
    $r = Invoke-WebRequest -Uri $uri -Headers $h -Method Put -Body ($obj | ConvertTo-Json -Depth 10)
    Write-Host ("PUT {0} -> {1}" -f $path, $r.StatusCode)
}
# Named value aoai-key (secret)
Put "namedValues/aoai-key" @{ properties = @{ displayName = 'aoai-key'; secret = $true; value = $AiKey } }
# contentsafety-backend with api-key credential
Put "backends/contentsafety-backend" @{ properties = @{
    url = 'https://<your-ai-account>.cognitiveservices.azure.com'
    protocol = 'http'
    credentials = @{ header = @{ 'api-key' = @('{{aoai-key}}') } }
} }
# api-key policy (no MI, keeps llm-content-safety)
$xml = Get-Content -Raw (Join-Path $PSScriptRoot 'apikey-api-policy.xml')
Put "apis/$api/policies/policy" @{ properties = @{ format = 'rawxml'; value = $xml } }
Write-Host '=== APIKEY POLICY APPLIED ==='
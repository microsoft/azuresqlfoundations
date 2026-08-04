$apiVersion = '2024-06-01-preview'
$baseUrl = "https://management.azure.com/subscriptions/<your-subscription-id>/resourceGroups/<your-resource-group>/providers/Microsoft.ApiManagement/service/zavafin-ai-gateway"

# Simpler policy - no on-error section, just content safety in inbound
$policyXml = @'
<policies>
  <inbound>
    <base />
    <set-backend-service backend-id="phi4-backend" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <azure-openai-token-limit tokens-per-minute="10000" counter-key="@(context.Subscription.Id)" estimate-prompt-tokens="true" />
    <llm-content-safety backend-id="contentsafety-backend">
      <categories>
        <category name="Hate" threshold="0" />
        <category name="Sexual" threshold="0" />
        <category name="SelfHarm" threshold="0" />
        <category name="Violence" threshold="0" />
      </categories>
    </llm-content-safety>
    <azure-openai-emit-token-metric namespace="zavafin-ai-gateway">
      <dimension name="Subscription" value="@(context.Subscription.Id)" />
      <dimension name="API" value="@(context.Api.Name)" />
    </azure-openai-emit-token-metric>
  </inbound>
  <backend>
    <forward-request timeout="120" />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
'@

$body = @{ properties = @{ format = "xml"; value = $policyXml } } | ConvertTo-Json -Depth 5 -Compress
$bodyFile = Join-Path $env:TEMP "cs-policy.json"
[System.IO.File]::WriteAllText($bodyFile, $body, [System.Text.UTF8Encoding]::new($false))

$url = "$baseUrl/apis/azure-openai-api/policies/policy?api-version=$apiVersion"

Write-Host "Applying content safety policy..."
# Capture stderr separately
$result = az rest --method PUT --url $url --body "@$bodyFile" 2>&1
$exitCode = $LASTEXITCODE
Write-Host "Exit code: $exitCode"

# Show any error details
$errors = $result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
if ($errors) {
    Write-Host "Errors:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host $_.ToString() }
}

$nonErrors = $result | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
if ($nonErrors) {
    Write-Host "Output:" -ForegroundColor Gray
    $nonErrors | Out-String | Write-Host
}

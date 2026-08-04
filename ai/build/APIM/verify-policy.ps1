$url = "https://management.azure.com/subscriptions/<your-subscription-id>/resourceGroups/<your-resource-group>/providers/Microsoft.ApiManagement/service/zavafin-ai-gateway/apis/azure-openai-api/policies/policy?api-version=2024-06-01-preview"
$outFile = Join-Path $env:TEMP "policy-verify.txt"
az rest --method GET --url $url --output-file $outFile 2>$null
$content = [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
if ($content -match 'llm-content-safety') {
    Write-Host "Content safety policy IS present" -ForegroundColor Green
    # Extract just the content-safety element
    if ($content -match '(llm-content-safety[^/]*/llm-content-safety)') { Write-Host "  $($Matches[0])" }
} else {
    Write-Host "Content safety policy NOT found" -ForegroundColor Red
    Write-Host $content.Substring(0, [Math]::Min(500, $content.Length))
}

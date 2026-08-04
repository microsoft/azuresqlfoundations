$ErrorActionPreference = 'Continue'
$url = 'https://zavafin-ai-gateway.azure-api.net/openai/deployments/Phi-4/chat/completions?api-version=2024-08-01-preview'
$key = '<your-apim-subscription-key>'
$headers = @{ 'Ocp-Apim-Subscription-Key' = $key; 'Content-Type' = 'application/json' }
$body = '{"messages":[{"role":"user","content":"Reply with the single word OK."}],"max_tokens":5,"temperature":0}'
$ok = 0; $hang = 0
for ($i = 1; $i -le 8; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $r = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body $body -TimeoutSec 15
        $sw.Stop()
        $ok++
        Write-Host ("iter {0}: OK   {1} ms  content='{2}'" -f $i, $sw.ElapsedMilliseconds, $r.choices[0].message.content)
    } catch {
        $sw.Stop()
        $hang++
        $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
        Write-Host ("iter {0}: FAIL {1} ms  err={2} httpcode={3}" -f $i, $sw.ElapsedMilliseconds, $_.Exception.Message, $code)
    }
}
Write-Host ("SUMMARY: ok={0} hang/fail={1}" -f $ok, $hang)
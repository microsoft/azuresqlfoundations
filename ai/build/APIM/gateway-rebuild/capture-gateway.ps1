# Captures the full zavafin-ai-gateway APIM configuration to JSON files for faithful rebuild.
$ErrorActionPreference = 'Continue'
$g   = '<your-resource-group>'
$s   = 'zavafin-ai-gateway'
$api = 'azure-openai-api'
$out = $PSScriptRoot
function Save($name, $json) { $json | Out-File -FilePath (Join-Path $out "$name.json") -Encoding utf8; Write-Host "saved $name.json" }

Save 'service'        (az apim show -n $s -g $g -o json)
Save 'apis'           (az apim api list -n $s -g $g -o json)
Save 'api-operations' (az apim api operation list -n $s -g $g --api-id $api -o json)
Save 'backends'       (az apim backend list -n $s -g $g -o json)
Save 'namedvalues'    (az apim nv list -n $s -g $g -o json)
Save 'products'       (az apim product list -n $s -g $g -o json)
Save 'subscriptions'  (az apim subscription list -n $s -g $g -o json)

# Subscription keys (secrets) - capture so the SQL credential can be preserved/recreated
$subs = az apim subscription list -n $s -g $g --query "[].name" -o tsv
$keyMap = @{}
foreach ($sid in $subs) {
    $k = az apim subscription show -n $s -g $g --sid $sid --query "{name:name,displayName:displayName,scope:scope,primaryKey:primaryKey,secondaryKey:secondaryKey}" -o json 2>$null
    if ($k) { $keyMap[$sid] = ($k | ConvertFrom-Json) }
}
($keyMap | ConvertTo-Json -Depth 5) | Out-File (Join-Path $out 'subscription-keys.json') -Encoding utf8
Write-Host 'saved subscription-keys.json'

# API-level policy (rawxml) via ARM (az rest chokes on BOM; use Invoke-RestMethod)
$tok = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$puri = "https://management.azure.com/subscriptions/<your-subscription-id>/resourceGroups/$g/providers/Microsoft.ApiManagement/service/$s/apis/$api/policies/policy?api-version=2024-05-01&format=rawxml"
$pol = Invoke-RestMethod -Uri $puri -Headers @{ Authorization = "Bearer $tok" } -Method Get
$pol.properties.value | Out-File (Join-Path $out 'api-policy.xml') -Encoding utf8
Write-Host 'saved api-policy.xml'

# Global policy
$guri = "https://management.azure.com/subscriptions/<your-subscription-id>/resourceGroups/$g/providers/Microsoft.ApiManagement/service/$s/policies/policy?api-version=2024-05-01&format=rawxml"
try { $gpol = Invoke-RestMethod -Uri $guri -Headers @{ Authorization = "Bearer $tok" } -Method Get; $gpol.properties.value | Out-File (Join-Path $out 'global-policy.xml') -Encoding utf8; Write-Host 'saved global-policy.xml' } catch { Write-Host 'no global policy' }

# Managed identity role assignments (so we can re-grant on rebuild)
$pid = az apim show -n $s -g $g --query "identity.principalId" -o tsv
if ($pid) {
    az role assignment list --assignee $pid --all -o json | Out-File (Join-Path $out 'mi-role-assignments.json') -Encoding utf8
    Write-Host "saved mi-role-assignments.json (principalId=$pid)"
}
Write-Host '=== CAPTURE COMPLETE ==='
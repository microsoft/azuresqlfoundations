[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $EnvironmentFile)) {
    throw "Environment file not found: $EnvironmentFile"
}

foreach ($line in Get-Content $EnvironmentFile) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
    $parts = $trimmed.Split('=', 2)
    if ($parts.Count -eq 2 -and -not [Environment]::GetEnvironmentVariable($parts[0])) {
        [Environment]::SetEnvironmentVariable($parts[0], $parts[1], 'Process')
    }
}

$required = @(
    'AZURE_RESOURCE_GROUP', 'AZURE_SQL_SERVER', 'AZURE_SQL_DATABASE',
    'CUSTOMER_APP_NAME', 'INTERNAL_APP_NAME', 'INTERNAL_AI_APP_NAME'
)
foreach ($name in $required) {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "Missing required environment value: $name" }
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw 'sqlcmd is required. Install the Microsoft sqlcmd utility, then rerun this script.'
}

$resourceGroup = $env:AZURE_RESOURCE_GROUP
$sqlServerHost = if ($env:AZURE_SQL_SERVER -match '\.database\.windows\.net$') {
    $env:AZURE_SQL_SERVER
} else {
    "$($env:AZURE_SQL_SERVER).database.windows.net"
}
$customerPrincipalId = az webapp identity show --resource-group $resourceGroup --name $env:CUSTOMER_APP_NAME --query principalId --output tsv
$internalPrincipalId = az webapp identity show --resource-group $resourceGroup --name $env:INTERNAL_APP_NAME --query principalId --output tsv
$internalAiPrincipalId = az webapp identity show --resource-group $resourceGroup --name $env:INTERNAL_AI_APP_NAME --query principalId --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve one or more App Service managed identities.' }

sqlcmd `
    -S $sqlServerHost `
    -d $env:AZURE_SQL_DATABASE `
    -G `
    -b `
    -l 30 `
    -i (Join-Path $PSScriptRoot 'sql/grant-app-identities.sql') `
    -v `
        CustomerIdentityName=$env:CUSTOMER_APP_NAME `
        CustomerPrincipalId=$customerPrincipalId `
        InternalIdentityName=$env:INTERNAL_APP_NAME `
        InternalPrincipalId=$internalPrincipalId `
        InternalAiIdentityName=$env:INTERNAL_AI_APP_NAME `
        InternalAiPrincipalId=$internalAiPrincipalId
if ($LASTEXITCODE -ne 0) { throw 'Database access configuration failed.' }

Write-Host 'Managed identity database access configured.'
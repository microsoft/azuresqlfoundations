[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '.env')
)

$ErrorActionPreference = 'Stop'

function Import-EnvironmentFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Environment file not found: $Path. Copy .env.example to .env and fill in the values."
    }

    foreach ($line in Get-Content $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = $trimmed.Split('=', 2)
        if ($parts.Count -eq 2 -and -not [Environment]::GetEnvironmentVariable($parts[0])) {
            [Environment]::SetEnvironmentVariable($parts[0], $parts[1], 'Process')
        }
    }
}

function Require-EnvironmentValue {
    param([string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) { throw "Missing required environment value: $Name" }
    return $value
}

Import-EnvironmentFile -Path $EnvironmentFile

$resourceGroup = Require-EnvironmentValue 'AZURE_RESOURCE_GROUP'
$location = Require-EnvironmentValue 'AZURE_LOCATION'
$planName = Require-EnvironmentValue 'APP_SERVICE_PLAN'
$customerApp = Require-EnvironmentValue 'CUSTOMER_APP_NAME'
$internalApp = Require-EnvironmentValue 'INTERNAL_APP_NAME'
$internalAiApp = Require-EnvironmentValue 'INTERNAL_AI_APP_NAME'
$sqlServer = Require-EnvironmentValue 'AZURE_SQL_SERVER'
$sqlDatabase = Require-EnvironmentValue 'AZURE_SQL_DATABASE'

az account show --output none
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI is not signed in. Run az login first.' }

$deployerPrincipalId = az ad signed-in-user show --query id --output tsv
if ($LASTEXITCODE -ne 0 -or -not $deployerPrincipalId) {
    throw 'Unable to resolve the signed-in Azure user object ID.'
}

az group show --name $resourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    az group create --name $resourceGroup --location $location --output none
    if ($LASTEXITCODE -ne 0) { throw 'Resource group creation failed.' }
}

$deploymentOutputs = az deployment group create `
    --resource-group $resourceGroup `
    --template-file (Join-Path $PSScriptRoot 'infra/main.bicep') `
    --parameters `
        location=$location `
        appServicePlanName=$planName `
        customerAppName=$customerApp `
        internalAppName=$internalApp `
        internalAiAppName=$internalAiApp `
        sqlServerName=$sqlServer `
        sqlDatabaseName=$sqlDatabase `
        deployerPrincipalId=$deployerPrincipalId `
    --query properties.outputs `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $deploymentOutputs) { throw 'App Service infrastructure deployment failed.' }

$storageAccount = $deploymentOutputs.packageStorageAccountName.value
$containerName = $deploymentOutputs.packageContainerName.value
$blobName = $deploymentOutputs.packageBlobName.value

$stagingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "zava-lending-$([guid]::NewGuid())"
$zipPath = "$stagingDirectory.zip"
try {
    npm ci --omit=dev --ignore-scripts
    if ($LASTEXITCODE -ne 0) { throw 'Production dependency installation failed.' }

    New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'server.js') $stagingDirectory
    Copy-Item (Join-Path $PSScriptRoot 'package.json') $stagingDirectory
    Copy-Item (Join-Path $PSScriptRoot 'package-lock.json') $stagingDirectory
    Copy-Item (Join-Path $PSScriptRoot 'shared') $stagingDirectory -Recurse
    Copy-Item (Join-Path $PSScriptRoot 'loan-platform-customer') $stagingDirectory -Recurse
    Copy-Item (Join-Path $PSScriptRoot 'loan-platform-internal') $stagingDirectory -Recurse
    Copy-Item (Join-Path $PSScriptRoot 'loan-platform-internal-ai') $stagingDirectory -Recurse
    Copy-Item (Join-Path $PSScriptRoot 'node_modules') $stagingDirectory -Recurse
    Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $zipPath -CompressionLevel Optimal

    Write-Host "Uploading application package to $storageAccount..."
    az storage blob upload `
        --account-name $storageAccount `
        --container-name $containerName `
        --name $blobName `
        --file $zipPath `
        --auth-mode login `
        --overwrite true `
        --content-type 'application/zip' `
        --output none
    if ($LASTEXITCODE -ne 0) { throw 'Application package upload failed.' }

    foreach ($appName in @($customerApp, $internalApp, $internalAiApp)) {
        Write-Host "Restarting $appName..."
        az webapp restart --resource-group $resourceGroup --name $appName --output none
        if ($LASTEXITCODE -ne 0) { throw "Application restart failed for $appName." }
    }
}
finally {
    Remove-Item $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
}

$identities = foreach ($appName in @($customerApp, $internalApp, $internalAiApp)) {
    [pscustomobject]@{
        AppName = $appName
        PrincipalId = az webapp identity show --resource-group $resourceGroup --name $appName --query principalId --output tsv
    }
}

Write-Host ''
Write-Host 'App Services deployed:'
$identities | ForEach-Object { Write-Host "  https://$($_.AppName).azurewebsites.net" }
Write-Host ''
Write-Host 'Next: grant these managed identities database access:'
$identities | Format-Table -AutoSize
Write-Host ".\configure-database-access.ps1 -EnvironmentFile '$EnvironmentFile'"
targetScope = 'resourceGroup'

@description('Azure region for the App Service resources.')
param location string = resourceGroup().location

@description('Name of the shared Linux App Service plan.')
param appServicePlanName string = 'zava-lending-plan'

@description('Globally unique name of the borrower-facing web app.')
param customerAppName string

@description('Globally unique name of the internal operations web app.')
param internalAppName string

@description('Globally unique name of the AI-enabled internal web app.')
param internalAiAppName string

@description('Azure SQL logical server name, without .database.windows.net.')
param sqlServerName string

@description('Azure SQL database name.')
param sqlDatabaseName string = 'ZavaLendingDB'

@description('Object ID of the user or service principal uploading the application package.')
param deployerPrincipalId string

@description('Globally unique storage account used for private application package hosting.')
param packageStorageAccountName string = 'zavapkg${uniqueString(subscription().id, resourceGroup().id)}'

@allowed([
  'B1'
  'S1'
  'P0v3'
  'P1v3'
])
@description('App Service plan SKU. B1 is suitable for workshop/demo use.')
param appServicePlanSku string = 'B1'

var apps = [
  {
    name: customerAppName
    kind: 'customer'
  }
  {
    name: internalAppName
    kind: 'internal'
  }
  {
    name: internalAiAppName
    kind: 'internal-ai'
  }
]
var packageContainerName = 'app-packages'
var packageBlobName = 'zava-lending.zip'
var storageBlobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var storageBlobDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')

resource packageStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: packageStorageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource packageBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: packageStorage
  name: 'default'
}

resource packageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: packageBlobService
  name: packageContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource packageUploader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(packageStorage.id, deployerPrincipalId, storageBlobDataContributorRoleId)
  scope: packageStorage
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: storageBlobDataContributorRoleId
  }
}

resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  sku: {
    name: appServicePlanSku
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource webApps 'Microsoft.Web/sites@2024-04-01' = [for app in apps: {
  name: app.name
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      alwaysOn: true
      ftpsState: 'Disabled'
      healthCheckPath: '/api/health'
      http20Enabled: true
      linuxFxVersion: 'NODE|20-lts'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'APP_KIND'
          value: app.kind
        }
        {
          name: 'AZURE_SQL_SERVER'
          value: sqlServerName
        }
        {
          name: 'AZURE_SQL_DATABASE'
          value: sqlDatabaseName
        }
        {
          name: 'NODE_ENV'
          value: 'production'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'false'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: 'https://${packageStorage.name}.blob.${environment().suffixes.storage}/${packageContainerName}/${packageBlobName}'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID'
          value: 'SystemAssigned'
        }
      ]
    }
  }
}]

resource appPackageReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (app, index) in apps: {
  name: guid(packageStorage.id, app.name, storageBlobDataReaderRoleId)
  scope: packageStorage
  properties: {
    principalId: webApps[index].identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}]

output customerAppHostname string = webApps[0].properties.defaultHostName
output internalAppHostname string = webApps[1].properties.defaultHostName
output internalAiAppHostname string = webApps[2].properties.defaultHostName
output appIdentities array = [for (app, index) in apps: {
  appName: app.name
  principalId: webApps[index].identity.principalId
}]
output packageStorageAccountName string = packageStorage.name
output packageContainerName string = packageContainer.name
output packageBlobName string = packageBlobName
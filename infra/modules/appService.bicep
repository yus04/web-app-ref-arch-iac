// ---------------------------------------------------------------------------
// App Service module
// Deploys a zone-redundant App Service plan (Premium v3) and a Linux Python web
// app with:
//   - System-assigned managed identity
//   - Regional VNet integration into the App Service integration subnet
//   - Public network access disabled (inbound only via the private endpoint)
//   - Application settings wired up for App Insights, PostgreSQL and Blob Storage
// ---------------------------------------------------------------------------

@description('Azure region for the App Service resources.')
param location string

@description('Name of the App Service plan.')
param appServicePlanName string

@description('Name of the App Service (web app).')
param appServiceName string

@description('Resource ID of the App Service integration (VNet integration) subnet.')
param appServiceSubnetId string

@description('Python runtime version, e.g. 3.12.')
param pythonVersion string = '3.12'

@description('App Service plan SKU name.')
param skuName string = 'P1v3'

@description('Number of instances (>= 2 for zone redundancy).')
param capacity int = 3

@description('Request zone redundancy. Automatically ignored when the selected SKU does not support it.')
param zoneRedundant bool = true

@description('Deploy Application Insights integration settings.')
param enableApplicationInsights bool = false

@description('Application Insights connection string.')
param applicationInsightsConnectionString string = ''

@description('Deploy PostgreSQL integration settings.')
param enablePostgres bool = false

@description('PostgreSQL host (FQDN).')
param postgresHost string = ''

@description('PostgreSQL database name.')
param postgresDatabase string = ''

@description('PostgreSQL Entra user (App Service name).')
param postgresUser string = ''

@description('Deploy Blob Storage integration settings.')
param enableStorage bool = false

@description('Storage account name.')
param storageAccountName string = ''

@description('Blob container name.')
param storageContainerName string = ''

@description('Allow public network access to the App Service. Set to true when no Application Gateway is deployed.')
param publicNetworkAccess bool = false

@description('Tags applied to the App Service resources.')
param tags object = {}

var baseAppSettings = [
  {
    name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
    value: 'true'
  }
  {
    name: 'ENABLE_ORYX_BUILD'
    value: 'true'
  }
]

var appInsightsSettings = enableApplicationInsights ? [
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: applicationInsightsConnectionString
  }
] : []

var postgresSettings = enablePostgres ? [
  {
    name: 'POSTGRES_HOST'
    value: postgresHost
  }
  {
    name: 'POSTGRES_DB'
    value: postgresDatabase
  }
  {
    name: 'POSTGRES_USER'
    value: postgresUser
  }
  {
    name: 'POSTGRES_PORT'
    value: '5432'
  }
  {
    name: 'POSTGRES_SSLMODE'
    value: 'require'
  }
] : []

var storageSettings = enableStorage ? [
  {
    name: 'AZURE_STORAGE_ACCOUNT_NAME'
    value: storageAccountName
  }
  {
    name: 'AZURE_STORAGE_CONTAINER_NAME'
    value: storageContainerName
  }
] : []

// Zone redundancy is only supported on Premium v2 / Premium v3 SKUs.
// For any other SKU (Basic, Standard, ...) it must not be requested, otherwise
// the deployment fails with 'SkuDoesNotSupportZoneRedundancy'.
var zoneRedundantSupportedSkus = [
  'P1v2'
  'P2v2'
  'P3v2'
  'P0v3'
  'P1v3'
  'P2v3'
  'P3v3'
  'P1mv3'
  'P2mv3'
  'P3mv3'
]
var skuSupportsZoneRedundancy = contains(zoneRedundantSupportedSkus, skuName)
var effectiveZoneRedundant = zoneRedundant && skuSupportsZoneRedundancy
// Zone-redundant plans require at least 2 instances.
var effectiveCapacity = effectiveZoneRedundant ? max(capacity, 2) : capacity

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: effectiveCapacity
  }
  kind: 'linux'
  properties: {
    reserved: true
    zoneRedundant: effectiveZoneRedundant
  }
}

resource appService 'Microsoft.Web/sites@2023-12-01' = {
  name: appServiceName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: publicNetworkAccess ? 'Enabled' : 'Disabled'
    virtualNetworkSubnetId: appServiceSubnetId
    vnetRouteAllEnabled: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|${pythonVersion}'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      appCommandLine: 'gunicorn --bind=0.0.0.0 --timeout 600 app:app'
      appSettings: concat(baseAppSettings, appInsightsSettings, postgresSettings, storageSettings)
    }
  }
}

output appServiceId string = appService.id
output appServiceName string = appService.name
output appServiceDefaultHostName string = appService.properties.defaultHostName
output principalId string = appService.identity.principalId

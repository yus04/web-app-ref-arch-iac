// ===========================================================================
// Azure Web Application reference architecture - main deployment
//
// Deploys a secure, zone-redundant web application platform:
//   - Virtual network with Application Gateway / App Service integration /
//     private endpoint subnets
//   - Zone-redundant App Service (Linux, Python) - always deployed
//   - Optional Application Gateway (WAF v2) paired with Azure Key Vault
//   - Optional Azure Database for PostgreSQL Flexible Server
//   - Optional Azure Blob Storage
//   - Optional Application Insights (+ Log Analytics)
//   - Optional DDoS protection plan
//   - Private endpoints and private DNS zones deployed only for the resources
//     that are actually deployed
//   - Least-privilege role assignments for the App Service managed identity
//
// Scope: resource group
// ===========================================================================

targetScope = 'resourceGroup'

// --------------------------- General parameters ----------------------------

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Short workload name used as a prefix for resource names (lowercase letters and numbers).')
@minLength(2)
@maxLength(12)
param workloadName string = 'webapp'

@description('Tags applied to all resources.')
param tags object = {}

// --------------------------- Feature toggles -------------------------------

@description('Deploy Application Gateway (WAF v2). Azure Key Vault is deployed together with it.')
param deployApplicationGateway bool = true

@description('Deploy Azure Database for PostgreSQL Flexible Server.')
param deployPostgreSql bool = true

@description('Deploy Azure Blob Storage.')
param deployStorage bool = true

@description('Deploy Application Insights (with Log Analytics workspace).')
param deployApplicationInsights bool = true

@description('Deploy a DDoS protection plan and associate it with the virtual network.')
param deployDdosProtection bool = false

// --------------------------- App Service parameters ------------------------

@description('App Service plan SKU name. Zone redundancy requires a Premium v2/v3 SKU (Pxv2 / Pxv3).')
@allowed([
  'B1'
  'B2'
  'B3'
  'S1'
  'S2'
  'S3'
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
])
param appServiceSkuName string = 'P1v3'

@description('Number of App Service plan instances. Must be >= 3 when zone redundancy is enabled.')
@minValue(1)
@maxValue(30)
param appServicePlanCapacity int = 3

@description('Enable zone redundancy for the App Service plan (requires a Premium v2/v3 SKU and capacity >= 3).')
param appServiceZoneRedundant bool = true

// --------------------------- Network parameters ----------------------------

@description('Address space (CIDR) of the virtual network.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Address prefix for the Application Gateway subnet.')
param appGatewaySubnetPrefix string = '10.0.1.0/24'

@description('Address prefix for the App Service integration subnet.')
param appServiceSubnetPrefix string = '10.0.2.0/24'

@description('Address prefix for the private endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.0.3.0/24'

// --------------------------- PostgreSQL parameters -------------------------

@description('Provision an additional Entra administrator (human/group) on PostgreSQL for manual management.')
param deployAdditionalPostgresAdmin bool = false

@description('Object ID of the additional PostgreSQL Entra administrator.')
param additionalPostgresAdminObjectId string = ''

@description('Principal name (UPN or group name) of the additional PostgreSQL Entra administrator.')
param additionalPostgresAdminName string = ''

@description('Principal type of the additional PostgreSQL Entra administrator.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param additionalPostgresAdminType string = 'User'

// --------------------------- Derived names ---------------------------------

var resourceToken = uniqueString(resourceGroup().id)
var vnetName = 'vnet-${workloadName}'
var appServicePlanName = 'plan-${workloadName}-${resourceToken}'
var appServiceName = 'app-${workloadName}-${resourceToken}'
var storageAccountName = take(toLower('st${replace(workloadName, '-', '')}${resourceToken}'), 24)
var storageContainerName = 'pdf'
var keyVaultName = take('kv-${workloadName}-${resourceToken}', 24)
var postgresServerName = 'psql-${workloadName}-${resourceToken}'
var postgresDatabaseName = 'appdb'
var applicationInsightsName = 'appi-${workloadName}-${resourceToken}'
var logAnalyticsWorkspaceName = 'log-${workloadName}-${resourceToken}'
var applicationGatewayName = 'agw-${workloadName}-${resourceToken}'

// Predicted PostgreSQL FQDN (avoids a circular dependency with App Service settings).
var postgresFqdn = '${postgresServerName}.postgres.database.azure.com'

// Private DNS zone names
var appServiceDnsZoneName = 'privatelink.azurewebsites.net'
var postgresDnsZoneName = 'privatelink.postgres.database.azure.com'
var keyVaultDnsZoneName = 'privatelink.vaultcore.azure.net'
var blobDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'

// --------------------------- DDoS protection plan --------------------------

resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2023-11-01' = if (deployDdosProtection) {
  name: 'ddos-${workloadName}'
  location: location
  tags: tags
}

// --------------------------- Network ---------------------------------------

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    vnetName: vnetName
    vnetAddressPrefix: vnetAddressPrefix
    appGatewaySubnetPrefix: appGatewaySubnetPrefix
    appServiceSubnetPrefix: appServiceSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    deployDdosProtection: deployDdosProtection
    ddosProtectionPlanId: deployDdosProtection ? ddosProtectionPlan.id : ''
    tags: tags
  }
}

// --------------------------- Private DNS zones -----------------------------

module appServiceDnsZone 'modules/privateDnsZone.bicep' = {
  name: 'dns-appservice'
  params: {
    zoneName: appServiceDnsZoneName
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

module postgresDnsZone 'modules/privateDnsZone.bicep' = if (deployPostgreSql) {
  name: 'dns-postgres'
  params: {
    zoneName: postgresDnsZoneName
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

module keyVaultDnsZone 'modules/privateDnsZone.bicep' = if (deployApplicationGateway) {
  name: 'dns-keyvault'
  params: {
    zoneName: keyVaultDnsZoneName
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

module blobDnsZone 'modules/privateDnsZone.bicep' = if (deployStorage) {
  name: 'dns-blob'
  params: {
    zoneName: blobDnsZoneName
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

// --------------------------- Monitoring ------------------------------------

module monitoring 'modules/monitoring.bicep' = if (deployApplicationInsights) {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    applicationInsightsName: applicationInsightsName
    tags: tags
  }
}

// --------------------------- Key Vault (paired with App Gateway) -----------

module keyVault 'modules/keyVault.bicep' = if (deployApplicationGateway) {
  name: 'keyvault'
  params: {
    location: location
    keyVaultName: keyVaultName
    tags: tags
  }
}

// --------------------------- Storage ---------------------------------------

module storage 'modules/storage.bicep' = if (deployStorage) {
  name: 'storage'
  params: {
    location: location
    storageAccountName: storageAccountName
    containerName: storageContainerName
    tags: tags
  }
}

// --------------------------- App Service -----------------------------------

module appService 'modules/appService.bicep' = {
  name: 'appservice'
  params: {
    location: location
    appServicePlanName: appServicePlanName
    appServiceName: appServiceName
    appServiceSubnetId: network.outputs.appServiceSubnetId
    skuName: appServiceSkuName
    capacity: appServicePlanCapacity
    zoneRedundant: appServiceZoneRedundant
    enableApplicationInsights: deployApplicationInsights
    applicationInsightsConnectionString: deployApplicationInsights ? monitoring!.outputs.connectionString : ''
    enablePostgres: deployPostgreSql
    postgresHost: postgresFqdn
    postgresDatabase: postgresDatabaseName
    postgresUser: appServiceName
    enableStorage: deployStorage
    storageAccountName: storageAccountName
    storageContainerName: storageContainerName
    tags: tags
  }
}

// --------------------------- PostgreSQL ------------------------------------

module postgres 'modules/postgresql.bicep' = if (deployPostgreSql) {
  name: 'postgres'
  params: {
    location: location
    serverName: postgresServerName
    databaseName: postgresDatabaseName
    appServicePrincipalId: appService.outputs.principalId
    appServicePrincipalName: appService.outputs.appServiceName
    deployAdditionalAdmin: deployAdditionalPostgresAdmin
    additionalAdminObjectId: additionalPostgresAdminObjectId
    additionalAdminName: additionalPostgresAdminName
    additionalAdminType: additionalPostgresAdminType
    tags: tags
  }
}

// --------------------------- Role assignments ------------------------------

module roleAssignments 'modules/roleAssignments.bicep' = {
  name: 'roleassignments'
  params: {
    principalId: appService.outputs.principalId
    assignStorageRole: deployStorage
    storageAccountName: storageAccountName
    assignAppInsightsRole: deployApplicationInsights
    applicationInsightsName: applicationInsightsName
    assignKeyVaultRole: deployApplicationGateway
    keyVaultName: keyVaultName
  }
  dependsOn: [
    storage
    keyVault
  ]
}

// --------------------------- Private endpoints -----------------------------

module appServicePrivateEndpoint 'modules/privateEndpoint.bicep' = {
  name: 'pe-appservice'
  params: {
    name: 'pe-${appServiceName}'
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    privateLinkServiceId: appService.outputs.appServiceId
    groupIds: [
      'sites'
    ]
    privateDnsZoneId: appServiceDnsZone.outputs.privateDnsZoneId
    tags: tags
  }
}

module postgresPrivateEndpoint 'modules/privateEndpoint.bicep' = if (deployPostgreSql) {
  name: 'pe-postgres'
  params: {
    name: 'pe-${postgresServerName}'
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    privateLinkServiceId: postgres!.outputs.postgresServerId
    groupIds: [
      'postgresqlServer'
    ]
    privateDnsZoneId: postgresDnsZone!.outputs.privateDnsZoneId
    tags: tags
  }
}

module keyVaultPrivateEndpoint 'modules/privateEndpoint.bicep' = if (deployApplicationGateway) {
  name: 'pe-keyvault'
  params: {
    name: 'pe-${keyVaultName}'
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    privateLinkServiceId: keyVault!.outputs.keyVaultId
    groupIds: [
      'vault'
    ]
    privateDnsZoneId: keyVaultDnsZone!.outputs.privateDnsZoneId
    tags: tags
  }
}

module storagePrivateEndpoint 'modules/privateEndpoint.bicep' = if (deployStorage) {
  name: 'pe-storage'
  params: {
    name: 'pe-${storageAccountName}'
    location: location
    subnetId: network.outputs.privateEndpointSubnetId
    privateLinkServiceId: storage!.outputs.storageAccountId
    groupIds: [
      'blob'
    ]
    privateDnsZoneId: blobDnsZone!.outputs.privateDnsZoneId
    tags: tags
  }
}

// --------------------------- Application Gateway ---------------------------

module applicationGateway 'modules/applicationGateway.bicep' = if (deployApplicationGateway) {
  name: 'appgateway'
  params: {
    location: location
    applicationGatewayName: applicationGatewayName
    appGatewaySubnetId: network.outputs.appGatewaySubnetId
    appServiceHostName: appService.outputs.appServiceDefaultHostName
    keyVaultName: keyVaultName
    tags: tags
  }
  dependsOn: [
    keyVault
    appServicePrivateEndpoint
  ]
}

// --------------------------- Outputs ---------------------------------------

output resourceGroupName string = resourceGroup().name
output appServiceName string = appService.outputs.appServiceName
output appServiceDefaultHostName string = appService.outputs.appServiceDefaultHostName
output appServicePrincipalId string = appService.outputs.principalId
output vnetName string = network.outputs.vnetName
output applicationInsightsName string = deployApplicationInsights ? applicationInsightsName : ''
output storageAccountName string = deployStorage ? storageAccountName : ''
output storageContainerName string = deployStorage ? storageContainerName : ''
output keyVaultName string = deployApplicationGateway ? keyVaultName : ''
output postgresServerName string = deployPostgreSql ? postgresServerName : ''
output postgresFqdn string = deployPostgreSql ? postgresFqdn : ''
output postgresDatabaseName string = deployPostgreSql ? postgresDatabaseName : ''
output applicationGatewayPublicIp string = deployApplicationGateway ? applicationGateway!.outputs.publicIpAddress : ''

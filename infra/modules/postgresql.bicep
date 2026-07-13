// ---------------------------------------------------------------------------
// PostgreSQL module
// Deploys an Azure Database for PostgreSQL Flexible Server configured for
// Microsoft Entra (Azure AD) authentication only (passwordless). Public network
// access is disabled; connectivity is via the private endpoint.
//
// The App Service managed identity is registered as an Entra administrator so
// the application can connect passwordless. An optional additional human/group
// administrator can be provisioned for manual management.
// ---------------------------------------------------------------------------

@description('Azure region for the PostgreSQL flexible server.')
param location string

@description('Name of the PostgreSQL flexible server.')
param serverName string

@description('Name of the application database to create.')
param databaseName string = 'appdb'

@description('PostgreSQL major version.')
param postgresVersion string = '16'

@description('Compute SKU name for the flexible server.')
param skuName string = 'Standard_B1ms'

@description('Compute tier for the flexible server.')
@allowed([
  'Burstable'
  'GeneralPurpose'
  'MemoryOptimized'
])
param skuTier string = 'Burstable'

@description('Storage size in GB.')
param storageSizeGB int = 32

@description('Object (principal) ID of the App Service system-assigned managed identity.')
param appServicePrincipalId string

@description('Principal name of the App Service managed identity (typically the App Service name).')
param appServicePrincipalName string

@description('Provision an additional Entra administrator (human/group) for manual management.')
param deployAdditionalAdmin bool = false

@description('Object ID of the additional Entra administrator.')
param additionalAdminObjectId string = ''

@description('Principal name (UPN or group name) of the additional Entra administrator.')
param additionalAdminName string = ''

@description('Principal type of the additional Entra administrator.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param additionalAdminType string = 'User'

@description('Tags applied to the flexible server.')
param tags object = {}

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    storage: {
      storageSizeGB: storageSizeGB
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Disabled'
      tenantId: subscription().tenantId
    }
    network: {
      publicNetworkAccess: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
  }
}

// Register the App Service managed identity as an Entra administrator so the
// application can authenticate passwordless.
resource appServiceAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = {
  parent: postgresServer
  name: appServicePrincipalId
  properties: {
    principalName: appServicePrincipalName
    principalType: 'ServicePrincipal'
    tenantId: subscription().tenantId
  }
}

// Optional additional (human/group) administrator for manual database management.
// Only deployed when a distinct object ID is supplied, to avoid colliding with the
// App Service managed identity administrator above.
resource additionalAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2024-08-01' = if (deployAdditionalAdmin && !empty(additionalAdminObjectId) && additionalAdminObjectId != appServicePrincipalId) {
  parent: postgresServer
  name: empty(additionalAdminObjectId) ? 'placeholder' : additionalAdminObjectId
  properties: {
    principalName: additionalAdminName
    principalType: additionalAdminType
    tenantId: subscription().tenantId
  }
  dependsOn: [
    appServiceAdmin
  ]
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgresServer
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  dependsOn: [
    appServiceAdmin
  ]
}

output postgresServerId string = postgresServer.id
output postgresServerName string = postgresServer.name
output postgresFqdn string = postgresServer.properties.fullyQualifiedDomainName
output databaseName string = database.name

// ---------------------------------------------------------------------------
// Role assignments module
// Grants the App Service system-assigned managed identity the least-privilege
// data-plane roles it needs on the optional resources it consumes:
//   - Storage: Storage Blob Data Reader
//   - Application Insights: Monitoring Metrics Publisher
//   - Key Vault: Key Vault Secrets User
// Each assignment is only created when the corresponding resource is deployed.
// ---------------------------------------------------------------------------

@description('Object (principal) ID of the App Service managed identity.')
param principalId string

@description('Assign the Storage Blob Data Reader role.')
param assignStorageRole bool = false

@description('Name of the storage account to scope the role assignment to.')
param storageAccountName string = ''

@description('Assign the Monitoring Metrics Publisher role.')
param assignAppInsightsRole bool = false

@description('Name of the Application Insights component to scope the role assignment to.')
param applicationInsightsName string = ''

@description('Assign the Key Vault Secrets User role.')
param assignKeyVaultRole bool = false

@description('Name of the Key Vault to scope the role assignment to.')
param keyVaultName string = ''

// Built-in role definition IDs
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = if (assignStorageRole) {
  name: storageAccountName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = if (assignAppInsightsRole) {
  name: applicationInsightsName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (assignKeyVaultRole) {
  name: keyVaultName
}

resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignStorageRole) {
  name: guid(storageAccount.id, principalId, storageBlobDataReaderRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource appInsightsRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAppInsightsRole) {
  name: guid(applicationInsights.id, principalId, monitoringMetricsPublisherRoleId)
  scope: applicationInsights
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignKeyVaultRole) {
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

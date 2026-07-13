// ---------------------------------------------------------------------------
// Key Vault module
// Deploys an RBAC-enabled Key Vault with public network access disabled.
// The vault stores TLS certificates consumed by Application Gateway and any
// secrets/config consumed by the App Service application. Access is only
// possible through the Key Vault private endpoint.
// ---------------------------------------------------------------------------

@description('Azure region for the Key Vault.')
param location string

@description('Name of the Key Vault.')
param keyVaultName string

@description('Tags applied to the Key Vault.')
param tags object = {}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri

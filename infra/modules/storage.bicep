// ---------------------------------------------------------------------------
// Storage module
// Deploys a StorageV2 account with a blob container used by the application to
// serve PDF files. Public network access is disabled; access is only possible
// through the blob private endpoint using the App Service managed identity.
// ---------------------------------------------------------------------------

@description('Azure region for the storage account.')
param location string

@description('Name of the storage account (3-24 lowercase alphanumeric characters).')
param storageAccountName string

@description('Name of the blob container used to store PDF files.')
param containerName string = 'pdf'

@description('Tags applied to the storage account.')
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_ZRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {}
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output containerName string = container.name

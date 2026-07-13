// ---------------------------------------------------------------------------
// Private endpoint module
// Creates a private endpoint for a target PaaS resource and registers its
// private DNS zone group so DNS records are created automatically.
// ---------------------------------------------------------------------------

@description('Name of the private endpoint.')
param name string

@description('Azure region for the private endpoint.')
param location string

@description('Resource ID of the private endpoint subnet.')
param subnetId string

@description('Resource ID of the target PaaS resource (private link service).')
param privateLinkServiceId string

@description('Group IDs (sub-resources) for the private link connection, e.g. [ blob ] or [ sites ].')
param groupIds array

@description('Resource ID of the private DNS zone to associate with the endpoint.')
param privateDnsZoneId string

@description('Tags applied to the private endpoint.')
param tags object = {}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-connection'
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: groupIds
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'config'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output privateEndpointId string = privateEndpoint.id

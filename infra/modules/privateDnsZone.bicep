// ---------------------------------------------------------------------------
// Private DNS zone module
// Creates a private DNS zone and links it to the target virtual network so
// that private endpoint records resolve to private IP addresses inside the VNet.
// ---------------------------------------------------------------------------

@description('Fully qualified private DNS zone name for the target private link resource.')
param zoneName string

@description('Resource ID of the virtual network to link the zone to.')
param vnetId string

@description('Tags applied to the private DNS zone.')
param tags object = {}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${uniqueString(vnetId)}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

output privateDnsZoneId string = privateDnsZone.id
output privateDnsZoneName string = privateDnsZone.name

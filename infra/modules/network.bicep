// ---------------------------------------------------------------------------
// Network module
// Deploys the virtual network, subnets and NSGs that host the workload.
//   - Application Gateway subnet
//   - App Service integration subnet (delegated to Microsoft.Web/serverFarms)
//   - Private endpoint subnet
// Optionally associates a DDoS protection plan with the virtual network.
// ---------------------------------------------------------------------------

@description('Azure region for all network resources.')
param location string

@description('Name of the virtual network.')
param vnetName string

@description('Address space (CIDR) of the virtual network.')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('Address prefix for the Application Gateway subnet.')
param appGatewaySubnetPrefix string = '10.0.1.0/24'

@description('Address prefix for the App Service regional VNet integration subnet.')
param appServiceSubnetPrefix string = '10.0.2.0/24'

@description('Address prefix for the private endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.0.3.0/24'

@description('Enable association of a DDoS protection plan.')
param deployDdosProtection bool = false

@description('Resource ID of a DDoS protection plan (required when deployDdosProtection is true).')
param ddosProtectionPlanId string = ''

@description('Deploy a NAT Gateway to give the App Service integration subnet a deterministic outbound internet path (required for Oryx build / App Insights telemetry when routing all egress through the VNet).')
param deployNatGateway bool = true

@description('Tags applied to all resources.')
param tags object = {}

var appGatewaySubnetName = 'snet-appgw'
var appServiceSubnetName = 'snet-appservice'
var privateEndpointSubnetName = 'snet-privateendpoint'

resource appGatewayNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${appGatewaySubnetName}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-GatewayManager-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'Allow-Internet-HttpHttps-Inbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource appServiceNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${appServiceSubnetName}'
  location: location
  tags: tags
  properties: {}
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-${privateEndpointSubnetName}'
  location: location
  tags: tags
  properties: {}
}

// NAT Gateway providing outbound internet access for the App Service integration subnet.
resource natGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (deployNatGateway) {
  name: 'pip-nat-${vnetName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = if (deployNatGateway) {
  name: 'nat-${vnetName}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natGatewayPublicIp.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    enableDdosProtection: deployDdosProtection
    ddosProtectionPlan: deployDdosProtection ? {
      id: ddosProtectionPlanId
    } : null
    subnets: [
      {
        name: appGatewaySubnetName
        properties: {
          addressPrefix: appGatewaySubnetPrefix
          networkSecurityGroup: {
            id: appGatewayNsg.id
          }
        }
      }
      {
        name: appServiceSubnetName
        properties: {
          addressPrefix: appServiceSubnetPrefix
          networkSecurityGroup: {
            id: appServiceNsg.id
          }
          natGateway: deployNatGateway ? {
            id: natGateway.id
          } : null
          delegations: [
            {
              name: 'appservice-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: {
            id: privateEndpointNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output appGatewaySubnetId string = vnet.properties.subnets[0].id
output appServiceSubnetId string = vnet.properties.subnets[1].id
output privateEndpointSubnetId string = vnet.properties.subnets[2].id

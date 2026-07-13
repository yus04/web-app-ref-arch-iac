// ---------------------------------------------------------------------------
// Application Gateway module
// Deploys an Application Gateway v2 with a WAF policy (OWASP, Prevention mode),
// a zonal public IP and a user-assigned managed identity that can read TLS
// certificates from Key Vault.
//
// The gateway is deployed with an HTTP (port 80) listener that forwards traffic
// to the App Service backend over HTTPS. The backend hostname resolves to the
// App Service private endpoint through the linked private DNS zone. Configuring
// an HTTPS listener with a custom domain / Key Vault certificate is a documented
// post-deployment step.
// ---------------------------------------------------------------------------

@description('Azure region for the Application Gateway.')
param location string

@description('Name of the Application Gateway.')
param applicationGatewayName string

@description('Resource ID of the Application Gateway subnet.')
param appGatewaySubnetId string

@description('Default hostname (FQDN) of the App Service backend, e.g. app.azurewebsites.net.')
param appServiceHostName string

@description('Name of the Key Vault the gateway identity may read certificates from.')
param keyVaultName string

@description('Availability zones for the gateway and public IP.')
param availabilityZones array = [
  '1'
  '2'
  '3'
]

@description('Tags applied to all resources.')
param tags object = {}

var publicIpName = 'pip-${applicationGatewayName}'
var wafPolicyName = 'waf-${applicationGatewayName}'
var identityName = 'id-${applicationGatewayName}'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

var gatewayId = resourceId('Microsoft.Network/applicationGateways', applicationGatewayName)

resource gatewayIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

// Allow the gateway identity to read certificates (stored as secrets) from Key Vault.
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, gatewayIdentity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: gatewayIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: availabilityZones
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource wafPolicy 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2023-11-01' = {
  name: wafPolicyName
  location: location
  tags: tags
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Prevention'
      requestBodyCheck: true
      maxRequestBodySizeInKb: 128
      fileUploadLimitInMb: 100
    }
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'OWASP'
          ruleSetVersion: '3.2'
        }
      ]
    }
  }
}

resource applicationGateway 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: applicationGatewayName
  location: location
  tags: tags
  zones: availabilityZones
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${gatewayIdentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 2
      maxCapacity: 5
    }
    firewallPolicy: {
      id: wafPolicy.id
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: appGatewaySubnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayPublicFrontendIp'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'appServiceBackendPool'
        properties: {
          backendAddresses: [
            {
              fqdn: appServiceHostName
            }
          ]
        }
      }
    ]
    probes: [
      {
        name: 'appServiceHttpsProbe'
        properties: {
          protocol: 'Https'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'appServiceHttpsSettings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: {
            id: '${gatewayId}/probes/appServiceHttpsProbe'
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'httpListener'
        properties: {
          frontendIPConfiguration: {
            id: '${gatewayId}/frontendIPConfigurations/appGatewayPublicFrontendIp'
          }
          frontendPort: {
            id: '${gatewayId}/frontendPorts/port_80'
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'httpRoutingRule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: '${gatewayId}/httpListeners/httpListener'
          }
          backendAddressPool: {
            id: '${gatewayId}/backendAddressPools/appServiceBackendPool'
          }
          backendHttpSettings: {
            id: '${gatewayId}/backendHttpSettingsCollection/appServiceHttpsSettings'
          }
        }
      }
    ]
  }
  dependsOn: [
    keyVaultRoleAssignment
  ]
}

output applicationGatewayId string = applicationGateway.id
output applicationGatewayName string = applicationGateway.name
output publicIpAddress string = publicIp.properties.ipAddress
output gatewayIdentityId string = gatewayIdentity.id
output gatewayIdentityClientId string = gatewayIdentity.properties.clientId

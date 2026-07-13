// ---------------------------------------------------------------------------
// Monitoring module
// Deploys a Log Analytics workspace and an Application Insights component
// (workspace-based). Application Insights is used by the App Service application
// to send OpenTelemetry data (authenticated with the App Service managed identity).
// ---------------------------------------------------------------------------

@description('Azure region for monitoring resources.')
param location string

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Name of the Application Insights component.')
param applicationInsightsName string

@description('Tags applied to all resources.')
param tags object = {}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output applicationInsightsId string = applicationInsights.id
output applicationInsightsName string = applicationInsights.name
output connectionString string = applicationInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

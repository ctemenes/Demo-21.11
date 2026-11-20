// Azure side of the service request integration.
// Everything signs in with managed identities. The only key issued is a
// send-only key on one queue, for the MuleSoft application.

targetScope = 'resourceGroup'

@description('Short name used in every resource name.')
@minLength(3)
@maxLength(10)
param prefix string = 'srint'

@description('Environment name, for example dev.')
param environment string = 'dev'

param location string = resourceGroup().location

@description('Object id of the Entra user or group that administers the SQL server.')
param sqlAdminObjectId string

@description('Sign-in name of that user or group.')
param sqlAdminLogin string

var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('${prefix}${environment}${take(suffix, 8)}')
var functionName = '${prefix}-${environment}-works-${take(suffix, 6)}'
var queueName = 'service-requests'
var deployContainer = 'function-releases'
var assetContainer = 'asset-register'
var tags = {
  project: 'service-request-integration'
  environment: environment
}

// ---------- Storage: function packages and the nightly asset register drop ----------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource releases 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deployContainer
}

resource assetDrop 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: assetContainer
}

// ---------- Service Bus: the queue between MuleSoft and the works system ----------
resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: '${prefix}-${environment}-sb-${take(suffix, 6)}'
  location: location
  tags: tags
  sku: { name: 'Basic', tier: 'Basic' }
  properties: { minimumTlsVersion: '1.2' }
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBus
  name: queueName
  properties: {
    maxDeliveryCount: 3
    lockDuration: 'PT1M'
    deadLetteringOnMessageExpiration: true
    defaultMessageTimeToLive: 'P7D'
  }
}

// MuleSoft can put messages on this one queue and do nothing else.
resource muleSendRule 'Microsoft.ServiceBus/namespaces/queues/authorizationRules@2022-10-01-preview' = {
  parent: queue
  name: 'mule-send'
  properties: { rights: ['Send'] }
}

// ---------- Monitoring ----------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-${environment}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-${environment}-insights'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------- Azure SQL: works management database (free serverless offer) ----------
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: '${prefix}-${environment}-sql-${take(suffix, 6)}'
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      login: sqlAdminLogin
      sid: sqlAdminObjectId
      tenantId: subscription().tenantId
      principalType: 'User'
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: 'works'
  location: location
  tags: tags
  sku: { name: 'GP_S_Gen5_2', tier: 'GeneralPurpose' }
  properties: {
    useFreeLimit: true
    freeLimitExhaustionBehavior: 'AutoPause'
    autoPauseDelay: 60
    minCapacity: json('0.5')
    maxSizeBytes: 34359738368
  }
}

// Lets Azure services (the Function App) reach the server. No other address is open.
resource sqlAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// ---------- Function App: the works system (Flex Consumption, Python) ----------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${prefix}-${environment}-plan'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  properties: { reserved: true }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deployContainer}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 40, instanceMemoryMB: 2048 }
      runtime: { name: 'python', version: '3.11' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: insights.properties.ConnectionString }
        { name: 'ServiceBusConnection__fullyQualifiedNamespace', value: '${serviceBus.name}.servicebus.windows.net' }
        { name: 'SERVICEBUS_QUEUE', value: queueName }
        { name: 'SQL_SERVER', value: sqlServer.properties.fullyQualifiedDomainName }
        { name: 'SQL_DATABASE', value: sqlDatabase.name }
      ]
    }
  }
}

// ---------- What the Function App's identity is allowed to do ----------
var roles = {
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  serviceBusDataReceiver: '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
}

resource functionStorageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, functionApp.id, roles.storageBlobDataOwner)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataOwner)
  }
}

resource functionQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: queue
  name: guid(queue.id, functionApp.id, roles.serviceBusDataReceiver)
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.serviceBusDataReceiver)
  }
}

output functionAppName string = functionApp.name
output functionHost string = functionApp.properties.defaultHostName
output serviceBusNamespace string = serviceBus.name
output queueName string = queueName
output storageAccount string = storage.name
output assetContainer string = assetContainer
output sqlServerHost string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabase string = sqlDatabase.name

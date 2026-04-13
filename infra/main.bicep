targetScope = 'resourceGroup'

@minLength(1)
param environmentName string
param location string
@minLength(1)
param prefix string = 'dify'

param postgresAdminUsername string = 'difyadmin'
@secure()
param postgresAdminPassword string
param postgresSkuName string = 'Standard_B1ms'
param postgresSkuTier string = 'Burstable'
param postgresStorageGb string = '32'

param redisSkuName string = 'Balanced_B0'

param difyApiImage string = 'langgenius/dify-api:1.13.3'
param difyWebImage string = 'langgenius/dify-web:1.13.3'
param difySandboxImage string = 'langgenius/dify-sandbox:0.2.14'
param difyPluginDaemonImage string = 'langgenius/dify-plugin-daemon:0.5.3-local'
param gatewayImage string = 'nginx:latest'
param ssrfProxyImage string = 'ubuntu/squid:latest'

param enableConsoleAuth string = 'false'
param entraTenantId string = ''
param entraClientId string = ''
@secure()
param entraClientSecret string = ''

@secure()
param difySecretKey string
@secure()
param difyInitPassword string
@secure()
param pluginDaemonKey string
@secure()
param pluginDifyInnerApiKey string
@secure()
param sandboxApiKey string
@secure()
param consoleAuthSigningKey string
@secure()
param consoleAuthEncryptionKey string

var consoleAuthEnabled = toLower(enableConsoleAuth) == 'true'
var shortUnique = take(toLower(uniqueString(subscription().subscriptionId, resourceGroup().id)), 6)
var envToken = toLower(replace(replace(environmentName, '_', '-'), '.', '-'))
var prefixToken = toLower(replace(replace(prefix, '_', '-'), '.', '-'))
var namePrefix = take('${prefixToken}-${envToken}', 20)
var storageName = take(replace('${prefixToken}${envToken}${shortUnique}st', '-', ''), 24)
var keyVaultName = take('${prefixToken}-${envToken}-${shortUnique}-kv', 24)
var logAnalyticsName = take('${prefixToken}-${envToken}-${shortUnique}-law', 63)
var managedEnvironmentName = take('${prefixToken}-${envToken}-${shortUnique}-acae', 32)
var postgresName = take('${prefixToken}-${envToken}-${shortUnique}-pg', 63)
var redisName = take('${prefixToken}-${envToken}-${shortUnique}-redis', 60)
var userAssignedIdentityName = take('${prefixToken}-${envToken}-${shortUnique}-uai', 64)

var apiAppName = take('${namePrefix}-api', 32)
var workerAppName = take('${namePrefix}-worker', 32)
var workerBeatAppName = take('${namePrefix}-beat', 32)
var webAppName = take('${namePrefix}-web', 32)
var pluginDaemonAppName = take('${namePrefix}-plugin', 32)
var sandboxAppName = take('${namePrefix}-sandbox', 32)
var ssrfProxyAppName = take('${namePrefix}-ssrf', 32)
var consoleGatewayAppName = take('${namePrefix}-console', 32)
var appGatewayAppName = take('${namePrefix}-public', 32)

var difyDatabaseName = 'dify'
var pluginDatabaseName = 'dify_plugin'
var difyBlobContainerName = 'dify-files'
var pluginBlobContainerName = 'dify-plugins'

var baseTags = {
  environment: environmentName
  managedBy: 'azd'
  workload: 'dify'
}
var tags = union(baseTags, {})

var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var storageBlobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource containerAppsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: userAssignedIdentityName
  location: location
  tags: tags
}

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
}

resource difyBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: difyBlobContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource pluginBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: pluginBlobContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, containerAppsIdentity.id, storageBlobDataContributorRoleId)
  scope: storage
  properties: {
    principalId: containerAppsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
}

resource postgres 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: postgresName
  location: location
  tags: tags
  sku: {
    name: postgresSkuName
    tier: postgresSkuTier
  }
  properties: {
    createMode: 'Create'
    version: '16'
    administratorLogin: postgresAdminUsername
    administratorLoginPassword: postgresAdminPassword
    authConfig: {
      activeDirectoryAuth: 'Disabled'
      passwordAuth: 'Enabled'
    }
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      publicNetworkAccess: 'Enabled'
    }
    storage: {
      storageSizeGB: int(postgresStorageGb)
      autoGrow: 'Enabled'
      type: 'Premium_LRS'
    }
  }
}

resource postgresAllowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: postgres
  name: 'allow-azure-services'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource postgresAllowExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2024-08-01' = {
  parent: postgres
  name: 'azure.extensions'
  properties: {
    source: 'user-override'
    value: 'vector,uuid-ossp'
  }
}

resource difyDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: difyDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

resource pluginDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2024-08-01' = {
  parent: postgres
  name: pluginDatabaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
}

resource redis 'Microsoft.Cache/redisEnterprise@2025-04-01' = {
  name: redisName
  location: location
  tags: tags
  sku: {
    name: redisSkuName
  }
  properties: {
    highAvailability: 'Disabled'
    minimumTlsVersion: '1.2'
  }
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' = {
  parent: redis
  name: 'default'
  properties: {
    accessKeysAuthentication: 'Enabled'
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'OSSCluster'
    evictionPolicy: 'AllKeysLRU'
    port: 10000
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
  }
}

resource keyVaultSecretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, containerAppsIdentity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: containerAppsIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

var storageAccountKey = storage.listKeys().keys[0].value
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storageAccountKey};EndpointSuffix=${environment().suffixes.storage}'
var redisPrimaryKey = redisDatabase.listKeys().primaryKey
var redisPort = string(redisDatabase.properties.port)
var redisCeleryBrokerUrl = 'rediss://:${redisPrimaryKey}@${redis.properties.hostName}:${redisPort}/1?ssl_cert_reqs=required'

resource secretDifySecretKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'dify-secret-key'
  properties: {
    value: difySecretKey
  }
}

resource secretDifyInitPassword 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'dify-init-password'
  properties: {
    value: difyInitPassword
  }
}

resource secretPostgresAdminPassword 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'postgres-admin-password'
  properties: {
    value: postgresAdminPassword
  }
}

resource secretRedisPrimaryKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'redis-primary-key'
  properties: {
    value: redisPrimaryKey
  }
}

resource secretRedisCeleryBroker 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'redis-celery-broker-url'
  properties: {
    value: redisCeleryBrokerUrl
  }
}

resource secretStorageAccountKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'storage-account-key'
  properties: {
    value: storageAccountKey
  }
}

resource secretPluginStorageConnectionString 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'plugin-storage-connection-string'
  properties: {
    value: storageConnectionString
  }
}

resource secretPluginDaemonKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'plugin-daemon-key'
  properties: {
    value: pluginDaemonKey
  }
}

resource secretPluginDifyInnerApiKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'plugin-dify-inner-api-key'
  properties: {
    value: pluginDifyInnerApiKey
  }
}

resource secretSandboxApiKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'sandbox-api-key'
  properties: {
    value: sandboxApiKey
  }
}

resource secretConsoleAuthClientSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'console-auth-client-secret'
  properties: {
    value: entraClientSecret
  }
}

resource secretConsoleAuthSigningKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'console-auth-signing-key'
  properties: {
    value: consoleAuthSigningKey
  }
}

resource secretConsoleAuthEncryptionKey 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: keyVault
  name: 'console-auth-encryption-key'
  properties: {
    value: consoleAuthEncryptionKey
  }
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: managedEnvironmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: listKeys(logAnalytics.id, logAnalytics.apiVersion).primarySharedKey
      }
    }
    peerAuthentication: {
      mtls: {
        enabled: false
      }
    }
    peerTrafficConfiguration: {
      encryption: {
        enabled: true
      }
    }
    zoneRedundant: false
  }
}

var consoleUrl = 'https://${consoleGatewayAppName}.${managedEnvironment.properties.defaultDomain}'
var appUrl = 'https://${appGatewayAppName}.${managedEnvironment.properties.defaultDomain}'
var apiInternalFqdn = '${apiAppName}.internal.${managedEnvironment.properties.defaultDomain}'
var webInternalFqdn = '${webAppName}.internal.${managedEnvironment.properties.defaultDomain}'
var pluginDaemonInternalFqdn = '${pluginDaemonAppName}.internal.${managedEnvironment.properties.defaultDomain}'
var apiInternalUrl = 'https://${apiInternalFqdn}'
var pluginDaemonInternalUrl = 'https://${pluginDaemonInternalFqdn}'
var sandboxInternalUrl = 'http://${sandboxAppName}:8194'
var ssrfProxyInternalUrl = 'http://${ssrfProxyAppName}:3128'
var internalFilesUrl = '${apiInternalUrl}/files'
var storageBlobUrl = storage.properties.primaryEndpoints.blob

var sharedContainerAppSecrets = [
  {
    name: 'dify-secret-key'
    keyVaultUrl: secretDifySecretKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'dify-init-password'
    keyVaultUrl: secretDifyInitPassword.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'postgres-admin-password'
    keyVaultUrl: secretPostgresAdminPassword.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'redis-primary-key'
    keyVaultUrl: secretRedisPrimaryKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'redis-celery-broker-url'
    keyVaultUrl: secretRedisCeleryBroker.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'storage-account-key'
    keyVaultUrl: secretStorageAccountKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'plugin-storage-connection-string'
    keyVaultUrl: secretPluginStorageConnectionString.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'plugin-daemon-key'
    keyVaultUrl: secretPluginDaemonKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'plugin-dify-inner-api-key'
    keyVaultUrl: secretPluginDifyInnerApiKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'sandbox-api-key'
    keyVaultUrl: secretSandboxApiKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
]

var consoleAuthSecrets = consoleAuthEnabled ? [
  {
    name: 'console-auth-client-secret'
    keyVaultUrl: secretConsoleAuthClientSecret.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'console-auth-signing-key'
    keyVaultUrl: secretConsoleAuthSigningKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
  {
    name: 'console-auth-encryption-key'
    keyVaultUrl: secretConsoleAuthEncryptionKey.properties.secretUriWithVersion
    identity: containerAppsIdentity.id
  }
] : []

var consoleGatewayTemplate = loadTextContent('templates/console-gateway.conf')
var appGatewayTemplate = loadTextContent('templates/app-gateway.conf')
var ssrfProxyTemplate = loadTextContent('templates/ssrf-proxy.conf')
var initPasswordDisabled = difyInitPassword == '__DISABLED__'

var apiWorkerCommonEnv = concat([
  {
    name: 'CONSOLE_API_URL'
    value: consoleUrl
  }
  {
    name: 'CONSOLE_WEB_URL'
    value: consoleUrl
  }
  {
    name: 'SERVICE_API_URL'
    value: appUrl
  }
  {
    name: 'TRIGGER_URL'
    value: appUrl
  }
  {
    name: 'APP_API_URL'
    value: appUrl
  }
  {
    name: 'APP_WEB_URL'
    value: appUrl
  }
  {
    name: 'FILES_URL'
    value: '${appUrl}/files'
  }
  {
    name: 'INTERNAL_FILES_URL'
    value: internalFilesUrl
  }
  {
    name: 'SECRET_KEY'
    secretRef: 'dify-secret-key'
  }
], initPasswordDisabled ? [] : [
  {
    name: 'INIT_PASSWORD'
    secretRef: 'dify-init-password'
  }
], [
  {
    name: 'DB_TYPE'
    value: 'postgresql'
  }
  {
    name: 'DB_HOST'
    value: postgres.properties.fullyQualifiedDomainName
  }
  {
    name: 'DB_PORT'
    value: '5432'
  }
  {
    name: 'DB_DATABASE'
    value: difyDatabaseName
  }
  {
    name: 'DB_USERNAME'
    value: postgresAdminUsername
  }
  {
    name: 'DB_PASSWORD'
    secretRef: 'postgres-admin-password'
  }
  {
    name: 'DB_SSL_MODE'
    value: 'require'
  }
  {
    name: 'MIGRATION_ENABLED'
    value: 'true'
  }
  {
    name: 'REDIS_HOST'
    value: redis.properties.hostName
  }
  {
    name: 'REDIS_PORT'
    value: redisPort
  }
  {
    name: 'REDIS_PASSWORD'
    secretRef: 'redis-primary-key'
  }
  {
    name: 'REDIS_USE_SSL'
    value: 'true'
  }
  {
    name: 'REDIS_SSL_CERT_REQS'
    value: 'CERT_REQUIRED'
  }
  {
    name: 'REDIS_DB'
    value: '0'
  }
  {
    name: 'CELERY_BROKER_URL'
    secretRef: 'redis-celery-broker-url'
  }
  {
    name: 'CELERY_BACKEND'
    value: 'redis'
  }
  {
    name: 'BROKER_USE_SSL'
    value: 'true'
  }
  {
    name: 'STORAGE_TYPE'
    value: 'azure-blob'
  }
  {
    name: 'AZURE_BLOB_ACCOUNT_NAME'
    value: storage.name
  }
  {
    name: 'AZURE_BLOB_ACCOUNT_KEY'
    secretRef: 'storage-account-key'
  }
  {
    name: 'AZURE_BLOB_CONTAINER_NAME'
    value: difyBlobContainerName
  }
  {
    name: 'AZURE_BLOB_ACCOUNT_URL'
    value: storageBlobUrl
  }
  {
    name: 'VECTOR_STORE'
    value: 'pgvector'
  }
  {
    name: 'PGVECTOR_HOST'
    value: postgres.properties.fullyQualifiedDomainName
  }
  {
    name: 'PGVECTOR_PORT'
    value: '5432'
  }
  {
    name: 'PGVECTOR_USER'
    value: postgresAdminUsername
  }
  {
    name: 'PGVECTOR_PASSWORD'
    secretRef: 'postgres-admin-password'
  }
  {
    name: 'PGVECTOR_DATABASE'
    value: difyDatabaseName
  }
  {
    name: 'PLUGIN_DAEMON_URL'
    value: pluginDaemonInternalUrl
  }
  {
    name: 'INNER_API_KEY_FOR_PLUGIN'
    secretRef: 'plugin-dify-inner-api-key'
  }
  {
    name: 'PLUGIN_REMOTE_INSTALL_HOST'
    value: pluginDaemonAppName
  }
  {
    name: 'PLUGIN_REMOTE_INSTALL_PORT'
    value: '5003'
  }
  {
    name: 'CODE_EXECUTION_ENDPOINT'
    value: sandboxInternalUrl
  }
  {
    name: 'CODE_EXECUTION_API_KEY'
    secretRef: 'sandbox-api-key'
  }
  {
    name: 'SSRF_PROXY_HTTP_URL'
    value: ssrfProxyInternalUrl
  }
  {
    name: 'SSRF_PROXY_HTTPS_URL'
    value: ssrfProxyInternalUrl
  }
  {
    name: 'RESPECT_XFORWARD_HEADERS_ENABLED'
    value: 'true'
  }
])

var apiEnv = concat(apiWorkerCommonEnv, [
  {
    name: 'MODE'
    value: 'api'
  }
  {
    name: 'PLUGIN_MAX_PACKAGE_SIZE'
    value: '52428800'
  }
  {
    name: 'PLUGIN_DAEMON_TIMEOUT'
    value: '600.0'
  }
])

var workerEnv = concat(apiWorkerCommonEnv, [
  {
    name: 'MODE'
    value: 'worker'
  }
  {
    name: 'PLUGIN_MAX_PACKAGE_SIZE'
    value: '52428800'
  }
])

var workerBeatEnv = concat(apiWorkerCommonEnv, [
  {
    name: 'MODE'
    value: 'beat'
  }
])

var webEnv = [
  {
    name: 'CONSOLE_API_URL'
    value: consoleUrl
  }
  {
    name: 'APP_API_URL'
    value: appUrl
  }
  {
    name: 'HOSTNAME'
    value: '0.0.0.0'
  }
  {
    name: 'NEXT_PUBLIC_COOKIE_DOMAIN'
    value: ''
  }
  {
    name: 'TEXT_GENERATION_TIMEOUT_MS'
    value: '60000'
  }
]

var pluginDaemonEnv = concat(apiWorkerCommonEnv, [
  {
    name: 'DB_DATABASE'
    value: pluginDatabaseName
  }
  {
    name: 'DB_SSL_MODE'
    value: 'require'
  }
  {
    name: 'SERVER_PORT'
    value: '5002'
  }
  {
    name: 'SERVER_KEY'
    secretRef: 'plugin-daemon-key'
  }
  {
    name: 'DIFY_INNER_API_URL'
    value: apiInternalUrl
  }
  {
    name: 'DIFY_INNER_API_KEY'
    secretRef: 'plugin-dify-inner-api-key'
  }
  {
    name: 'PLUGIN_REMOTE_INSTALLING_HOST'
    value: '0.0.0.0'
  }
  {
    name: 'PLUGIN_REMOTE_INSTALLING_PORT'
    value: '5003'
  }
  {
    name: 'PLUGIN_WORKING_PATH'
    value: '/app/storage/cwd'
  }
  {
    name: 'FORCE_VERIFYING_SIGNATURE'
    value: 'true'
  }
  {
    name: 'PLUGIN_STORAGE_TYPE'
    value: 'azure-blob'
  }
  {
    name: 'AZURE_BLOB_STORAGE_CONNECTION_STRING'
    secretRef: 'plugin-storage-connection-string'
  }
  {
    name: 'AZURE_BLOB_STORAGE_CONTAINER_NAME'
    value: pluginBlobContainerName
  }
])

var sandboxEnv = [
  {
    name: 'API_KEY'
    secretRef: 'sandbox-api-key'
  }
  {
    name: 'GIN_MODE'
    value: 'release'
  }
  {
    name: 'WORKER_TIMEOUT'
    value: '15'
  }
  {
    name: 'ENABLE_NETWORK'
    value: 'true'
  }
  {
    name: 'HTTP_PROXY'
    value: ssrfProxyInternalUrl
  }
  {
    name: 'HTTPS_PROXY'
    value: ssrfProxyInternalUrl
  }
  {
    name: 'SANDBOX_PORT'
    value: '8194'
  }
]

var consoleGatewayConfig = replace(replace(replace(consoleGatewayTemplate, '__API__', apiInternalFqdn), '__PLUGIN__', pluginDaemonInternalFqdn), '__WEB__', webInternalFqdn)
var appGatewayConfig = replace(replace(replace(appGatewayTemplate, '__API__', apiInternalFqdn), '__PLUGIN__', pluginDaemonInternalFqdn), '__WEB__', webInternalFqdn)
var consoleGatewayStart = concat('''
cat > /etc/nginx/conf.d/default.conf <<'EOF'
''', consoleGatewayConfig, '''
EOF
nginx -g 'daemon off;'
''')
var appGatewayStart = concat('''
cat > /etc/nginx/conf.d/default.conf <<'EOF'
''', appGatewayConfig, '''
EOF
nginx -g 'daemon off;'
''')
var ssrfProxyStart = concat('''
cat > /etc/squid/squid.conf <<'EOF'
''', ssrfProxyTemplate, '''
EOF
squid -NYCd 1
''')

module apiApp './modules/container-app.bicep' = {
  name: 'api-app'
  params: {
    name: apiAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: difyApiImage
    env: apiEnv
    secrets: sharedContainerAppSecrets
    targetPort: 5001
    external: false
    cpu: '1.0'
    memory: '2Gi'
  }
}

module workerApp './modules/container-app.bicep' = {
  name: 'worker-app'
  params: {
    name: workerAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: difyApiImage
    env: workerEnv
    secrets: sharedContainerAppSecrets
    cpu: '1.0'
    memory: '2Gi'
  }
}

module workerBeatApp './modules/container-app.bicep' = {
  name: 'worker-beat-app'
  params: {
    name: workerBeatAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: difyApiImage
    env: workerBeatEnv
    secrets: sharedContainerAppSecrets
    cpu: '0.5'
    memory: '1Gi'
  }
}

module webApp './modules/container-app.bicep' = {
  name: 'web-app'
  params: {
    name: webAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: difyWebImage
    env: webEnv
    secrets: sharedContainerAppSecrets
    targetPort: 3000
    external: false
    cpu: '0.5'
    memory: '1Gi'
  }
}

module pluginDaemonApp './modules/container-app.bicep' = {
  name: 'plugin-daemon-app'
  params: {
    name: pluginDaemonAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: difyPluginDaemonImage
    env: pluginDaemonEnv
    secrets: sharedContainerAppSecrets
    targetPort: 5002
    external: false
    cpu: '0.5'
    memory: '1Gi'
  }
}

module sandboxApp './modules/container-app.bicep' = {
  name: 'sandbox-app'
  params: {
    name: sandboxAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: difySandboxImage
    env: sandboxEnv
    secrets: sharedContainerAppSecrets
    targetPort: 8194
    external: false
    cpu: '0.5'
    memory: '1Gi'
  }
}

module ssrfProxyApp './modules/container-app.bicep' = {
  name: 'ssrf-proxy-app'
  params: {
    name: ssrfProxyAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: ssrfProxyImage
    command: [
      'sh'
      '-c'
    ]
    args: [
      ssrfProxyStart
    ]
    env: []
    secrets: sharedContainerAppSecrets
    targetPort: 3128
    external: false
    cpu: '0.25'
    memory: '0.5Gi'
  }
}

module consoleGatewayApp './modules/container-app.bicep' = {
  name: 'console-gateway-app'
  params: {
    name: consoleGatewayAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: gatewayImage
    command: [
      'sh'
      '-c'
    ]
    args: [
      consoleGatewayStart
    ]
    env: []
    secrets: concat(sharedContainerAppSecrets, consoleAuthSecrets)
    targetPort: 8080
    external: true
    cpu: '0.25'
    memory: '0.5Gi'
  }
}

module appGatewayApp './modules/container-app.bicep' = {
  name: 'app-gateway-app'
  params: {
    name: appGatewayAppName
    location: location
    tags: tags
    managedEnvironmentId: managedEnvironment.id
    userAssignedIdentityResourceId: containerAppsIdentity.id
    image: gatewayImage
    command: [
      'sh'
      '-c'
    ]
    args: [
      appGatewayStart
    ]
    env: []
    secrets: sharedContainerAppSecrets
    targetPort: 8080
    external: true
    cpu: '0.25'
    memory: '0.5Gi'
  }
}

resource consoleGatewayExisting 'Microsoft.App/containerApps@2025-01-01' existing = {
  name: consoleGatewayAppName
}

resource consoleGatewayAuth 'Microsoft.App/containerApps/authConfigs@2025-01-01' = if (consoleAuthEnabled) {
  name: 'current'
  parent: consoleGatewayExisting
  dependsOn: [
    consoleGatewayApp
  ]
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureActiveDirectory'
      excludedPaths: [
        '/install'
        '/init'
        '/console/api/setup'
        '/console/api/init'
        '/console/api/system-features'
      ]
    }
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
      forwardProxy: {
        convention: 'Standard'
      }
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: entraClientId
          clientSecretSettingName: 'console-auth-client-secret'
          openIdIssuer: 'https://login.microsoftonline.com/${entraTenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${entraClientId}'
            entraClientId
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

output RESOURCE_GROUP_NAME string = resourceGroup().name
output LOCATION string = location
output MANAGED_ENVIRONMENT_NAME string = managedEnvironment.name
output MANAGED_ENVIRONMENT_DEFAULT_DOMAIN string = managedEnvironment.properties.defaultDomain
output CONSOLE_URL string = consoleUrl
output APP_URL string = appUrl
output KEY_VAULT_NAME string = keyVault.name
output STORAGE_ACCOUNT_NAME string = storage.name
output DIFY_BLOB_CONTAINER_NAME string = difyBlobContainer.name
output PLUGIN_BLOB_CONTAINER_NAME string = pluginBlobContainer.name
output POSTGRES_SERVER_NAME string = postgres.name
output POSTGRES_SERVER_FQDN string = postgres.properties.fullyQualifiedDomainName
output POSTGRES_ADMIN_USERNAME string = postgresAdminUsername
output DIFY_DATABASE_NAME string = difyDatabase.name
output PLUGIN_DATABASE_NAME string = pluginDatabase.name
output REDIS_NAME string = redis.name
output REDIS_HOSTNAME string = redis.properties.hostName
output REDIS_PORT string = redisPort

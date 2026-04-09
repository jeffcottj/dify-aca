param name string
param location string
param tags object = {}
param managedEnvironmentId string
param userAssignedIdentityResourceId string
param image string
param command array = []
param args array = []
param env array = []
param secrets array = []
param targetPort int = 0
param external bool = false
param minReplicas int = 1
param maxReplicas int = 1
param cpu string = '0.5'
param memory string = '1Gi'

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    managedEnvironmentId: managedEnvironmentId
    configuration: union({
      activeRevisionsMode: 'Single'
      secrets: secrets
    }, targetPort > 0 ? {
      ingress: {
        allowInsecure: false
        external: external
        targetPort: targetPort
        transport: 'http'
      }
    } : {})
    template: {
      terminationGracePeriodSeconds: 60
      containers: [
        {
          name: name
          image: image
          command: command
          args: args
          env: env
          resources: {
            cpu: json(cpu)
            memory: memory
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}

output id string = app.id
output fqdn string = targetPort > 0 ? app.properties.configuration.ingress.fqdn : ''

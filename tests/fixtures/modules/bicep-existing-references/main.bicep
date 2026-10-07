targetScope = 'subscription'

extension microsoftGraphV1

param vaultName string
param vaultResourceGroupName string

resource backupManagementService 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: '262044b1-e2ce-469f-a196-69ab7ada62d3'
}

resource vault 'Microsoft.KeyVault/vaults@2026-02-01' existing = {
  scope: resourceGroup(vaultResourceGroupName)
  name: vaultName
}

module forward './dependency.bicep' = {
  name: 'existing-reference-consumer'
  params: {
    principalId: backupManagementService.id
    vaultId: vault.id
  }
}

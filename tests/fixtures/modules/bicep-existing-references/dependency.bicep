targetScope = 'subscription'

param principalId string
param vaultId string

output observedPrincipalId string = principalId
output observedVaultId string = vaultId

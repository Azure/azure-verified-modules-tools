using './main.bicep'

// Target subscription: c7fedf3b-cbde-4f68-8c81-7a0313adfc21
// Target tenant: 70a036f6-8e4d-4615-bad6-149c02e7720d
// The operator must select and verify this target before deployment; these comments do not set the scope.
param location = 'northeurope'
param resourceGroupName = 'rg-avm-repository-sync-state-tme'
param backendIdentityName = 'id-avm-repository-sync-state-tme'
param containerName = 'tfstate'
param githubRepositoryOwnerId = '6844498'
param githubRepositoryId = '1239632211'
param softDeleteRetentionDays = 7
param enableDeleteLock = true

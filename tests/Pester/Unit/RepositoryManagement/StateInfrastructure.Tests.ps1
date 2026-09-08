BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:main = Get-Content -Raw (Join-Path $script:root 'infra' 'main.bicep')
    $script:backend = Get-Content -Raw (Join-Path $script:root 'infra' 'modules' 'state-backend.bicep')
    $script:parameters = Get-Content -Raw (Join-Path $script:root 'infra' 'main.bicepparam')
}

Describe 'TME state infrastructure contract' {
    It 'creates a dedicated subscription-scope resource group in North Europe' {
        $script:main | Should -Match "targetScope = 'subscription'"
        $script:main | Should -Match "param location string = 'northeurope'"
        $script:parameters | Should -Match "param location = 'northeurope'"
        $script:main | Should -Match 'Microsoft.Resources/resourceGroups@'
        $script:main | Should -Match "resourceGroupName string = 'rg-avm-repository-sync-state-tme'"
    }

    It 'hardens blob storage and preserves recovery features' {
        foreach ($setting in @(
            "name: 'Standard_ZRS'",
            'allowBlobPublicAccess: false',
            'allowSharedKeyAccess: false',
            'supportsHttpsTrafficOnly: true',
            "minimumTlsVersion: 'TLS1_2'",
            "publicAccess: 'None'",
            'isVersioningEnabled: true',
            'deleteRetentionPolicy:',
            'containerDeleteRetentionPolicy:',
            "level: 'CanNotDelete'"
        )) {
            $script:backend | Should -Match ([regex]::Escape($setting))
        }
        $script:main | Should -Match '@minValue\(7\)'
    }

    It 'trusts the existing immutable repository ID and environment subject' {
        $script:parameters | Should -Match "githubRepositoryOwnerId = '6844498'"
        $script:parameters | Should -Match "githubRepositoryId = '1239632211'"
        $script:backend | Should -Match ([regex]::Escape(
            'repository_owner_id:${githubRepositoryOwnerId}:repository_id:${githubRepositoryId}:environment:avm'
        ))
        $script:backend | Should -Match "issuer: 'https://token.actions.githubusercontent.com'"
        $script:backend | Should -Match "'api://AzureADTokenExchange'"
    }

    It 'grants only container-scoped Blob Data Contributor to the backend identity' {
        ([regex]::Matches($script:backend, 'Microsoft.Authorization/roleAssignments@')).Count | Should -Be 1
        $script:backend | Should -Match "'ba92f5b4-2d11-453d-a403-e96b0029c9fe'"
        $script:backend | Should -Match '(?s)resource backendStateAccess.*?scope: stateContainer'
        $script:backend | Should -Match 'principalId: backendIdentity.properties.principalId'
        $script:backend | Should -Match "principalType: 'ServicePrincipal'"
    }

    It 'exports the workflow input map without secrets or deployment side effects' {
        $script:main | Should -Match 'output workflowVariables object ='
        foreach ($name in @(
            'ARM_BACKEND_CLIENT_ID', 'ARM_BACKEND_TENANT_ID', 'ARM_BACKEND_SUBSCRIPTION_ID',
            'STORAGE_ACCOUNT_NAME', 'STORAGE_ACCOUNT_RESOURCE_GROUP_NAME', 'STORAGE_ACCOUNT_CONTAINER_NAME'
        )) {
            $script:main | Should -Match ("(?m)^\s+" + $name + ':')
        }
        ($script:main + $script:backend) | Should -Not -Match 'listKeys|Microsoft.Resources/deploymentScripts'
    }
}

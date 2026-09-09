BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:main = Get-Content -Raw (Join-Path $script:root 'infra' 'main.tf')
    $script:variables = Get-Content -Raw (Join-Path $script:root 'infra' 'variables.tf')
    $script:providers = Get-Content -Raw (Join-Path $script:root 'infra' 'providers.tf')
    $script:terraform = Get-Content -Raw (Join-Path $script:root 'infra' 'terraform.tf')
    $script:outputs = Get-Content -Raw (Join-Path $script:root 'infra' 'outputs.tf')
}

Describe 'TME state infrastructure contract' {
    It 'pins AVM modules for every deployed resource family' {
        foreach ($entry in @(
            @{ Name = 'resources-resourcegroup'; Version = '0.4.0' }
            @{ Name = 'storage-storageaccount'; Version = '0.10.0' }
            @{ Name = 'managedidentity-userassignedidentity'; Version = '0.5.2' }
        )) {
            $script:main | Should -Match (
                'source\s*=\s*"Azure/avm-res-' + $entry.Name +
                '/azurerm"\s+version\s*=\s*"' + [regex]::Escape($entry.Version) + '"'
            )
        }
        $script:main | Should -Not -Match '(?m)^\s*resource\s+"'
        ([regex]::Matches($script:main, 'enable_telemetry\s*=\s*false')).Count | Should -Be 3
    }

    It 'targets the dedicated West US 3 TME resource group' {
        $script:variables | Should -Match 'default\s*=\s*"westus3"'
        $script:variables | Should -Match 'default\s*=\s*"c7fedf3b-cbde-4f68-8c81-7a0313adfc21"'
        $script:variables | Should -Match 'default\s*=\s*"70a036f6-8e4d-4615-bad6-149c02e7720d"'
        $script:variables | Should -Match 'default\s*=\s*"rg-avm-repository-sync-state-tme"'
        ([regex]::Matches($script:providers, 'subscription_id\s*=\s*var.subscription_id')).Count | Should -Be 2
        ([regex]::Matches($script:providers, 'tenant_id\s*=\s*var.tenant_id')).Count | Should -Be 2
    }

    It 'requires Entra ID and preserves recovery features' {
        foreach ($pattern in @(
            'account_sku_name\s*=\s*"Standard_ZRS"',
            'allow_nested_items_to_be_public\s*=\s*false',
            'shared_access_key_enabled\s*=\s*false',
            'default_to_oauth_authentication\s*=\s*true',
            'https_traffic_only_enabled\s*=\s*true',
            'min_tls_version\s*=\s*"TLS1_2"',
            'local_user_enabled\s*=\s*false',
            'public_access\s*=\s*"None"',
            'versioning_enabled\s*=\s*true',
            'delete_retention_policy\s*=\s*\{',
            'container_delete_retention_policy\s*=\s*\{',
            'kind\s*=\s*"CanNotDelete"'
        )) {
            $script:main | Should -Match $pattern
        }
        $script:providers | Should -Match 'storage_use_azuread\s*=\s*true'
        $script:variables | Should -Match 'var.soft_delete_retention_days >= 7'
    }

    It 'trusts the existing repository ID and environment subject' {
        $script:variables | Should -Match 'default\s*=\s*"6844498"'
        $script:variables | Should -Match 'default\s*=\s*"1239632211"'
        $script:main | Should -Match ([regex]::Escape(
            'repository_owner_id:${var.github_repository_owner_id}:repository_id:${var.github_repository_id}:environment:avm'
        ))
        $script:main | Should -Match 'issuer\s*=\s*"https://token.actions.githubusercontent.com"'
        $script:main | Should -Match '"api://AzureADTokenExchange"'
    }

    It 'grants container-only Blob Data Contributor to the UAMI' {
        ([regex]::Matches($script:main, 'role_assignments\s*=')).Count | Should -Be 1
        $script:main | Should -Match 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        $script:main | Should -Match '(?s)containers\s*=\s*\{.*?role_assignments\s*='
        $script:main | Should -Match 'principal_id\s*=\s*module.backend_identity.principal_id'
        $script:main | Should -Match 'principal_type\s*=\s*"ServicePrincipal"'
    }

    It 'uses disposable local bootstrap state with nonsecret handoff outputs' {
        $script:terraform | Should -Match 'backend "local" \{\}'
        $script:terraform | Should -Not -Match 'backend "azurerm"'
        $script:outputs | Should -Match 'output "workflowVariables"'
        foreach ($name in @(
            'ARM_BACKEND_CLIENT_ID', 'ARM_BACKEND_TENANT_ID', 'ARM_BACKEND_SUBSCRIPTION_ID',
            'ARM_BACKEND_STORAGE_ACCOUNT_NAME', 'ARM_BACKEND_STORAGE_CONTAINER_NAME'
        )) {
            $script:outputs | Should -Match ("(?m)^\s+" + $name + '\s*=')
        }
        $script:outputs | Should -Not -Match 'access_key|sas_token|client_secret'
        $script:outputs | Should -Not -Match '(?m)^\s+STORAGE_ACCOUNT_(NAME|RESOURCE_GROUP_NAME|CONTAINER_NAME)\s*='
        $script:outputs | Should -Match 'output "resourceGroupId"'
        Test-Path (Join-Path $script:root 'infra' 'main.bicep') | Should -BeFalse
        Test-Path (Join-Path $script:root 'infra' 'main.bicepparam') | Should -BeFalse
    }

    It 'keeps generated bootstrap outputs and dependency locks local-only' {
        $paths = @('infra/.terraform.lock.hcl', 'infra/tme.outputs.json')
        $tracked = @(& git -C $script:root ls-files -- @paths)
        $LASTEXITCODE | Should -Be 0
        $tracked | Should -BeNullOrEmpty
        $ignored = @(& git -C $script:root check-ignore --no-index -- @paths)
        $LASTEXITCODE | Should -Be 0
        $ignored | Should -Be $paths

        $build = Get-Content -Raw (Join-Path $script:root 'build' 'avm.build.ps1')
        $build | Should -Not -Match '-lockfile=readonly'
    }
}

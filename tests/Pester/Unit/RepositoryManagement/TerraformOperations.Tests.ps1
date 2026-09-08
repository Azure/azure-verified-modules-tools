BeforeAll {
    $script:repoRoot = (Resolve-Path (
        Join-Path $PSScriptRoot '..' '..' '..' '..'
    )).Path
    . (Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/lib/RetryHelpers.ps1'
        ))
    . (Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/lib/TerraformOperations.ps1'
        ))
}

Describe 'Invoke-TerraformInit' {
    It 'uses upgrade for the local backend' {
        Mock Invoke-TerraformWithRetry {
            [pscustomobject]@{ success = $true }
        }

        $null = Invoke-TerraformInit `
            -terraformModulePath $TestDrive `
            -repositoryCreationModeEnabled $true `
            -repoId 'example' `
            -orgAndRepoName 'Azure/example' `
            -stateResourceGroupName 'rg' `
            -stateStorageAccountName 'storage' `
            -stateContainerName 'state' `
            -issueLog @()

        Should -Invoke Invoke-TerraformWithRetry -Exactly 1 -ParameterFilter {
            $commands[0].Arguments -join ' ' -eq 'init -upgrade'
        }
    }

    It 'uses upgrade before remote backend configuration arguments' {
        Mock Invoke-TerraformWithRetry {
            [pscustomobject]@{ success = $true }
        }

        $null = Invoke-TerraformInit `
            -terraformModulePath $TestDrive `
            -repositoryCreationModeEnabled $false `
            -repoId 'example' `
            -orgAndRepoName 'Azure/example' `
            -stateResourceGroupName 'rg' `
            -stateStorageAccountName 'storage' `
            -stateContainerName 'state' `
            -issueLog @()

        Should -Invoke Invoke-TerraformWithRetry -Exactly 1 -ParameterFilter {
            $commands[0].Arguments[0] -eq 'init' -and
            $commands[0].Arguments[1] -eq '-upgrade' -and
            $commands[0].Arguments[2] -like '-backend-config=*'
        }
    }

    It 'leaves legacy backend identity discovery unchanged' {
        Mock Invoke-TerraformWithRetry { [pscustomobject]@{ success = $true } }
        $null = Invoke-TerraformInit -terraformModulePath $TestDrive `
            -repoId 'example' -stateStorageAccountName 'storage' -stateContainerName 'tfstate' -issueLog @()

        Should -Invoke Invoke-TerraformWithRetry -Exactly 1 -ParameterFilter {
            $commands[0].Arguments.Count -eq 6 -and
            ($commands[0].Arguments -join ' ') -notmatch '(tenant_id|client_id|subscription_id|oidc_token)='
        }
    }

    It 'pins only nonsecret backend metadata without changing provider environment' {
        $previous = @{}
        foreach ($name in 'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:ARM_CLIENT_ID = '11111111-1111-4111-8111-111111111111'
        $env:ARM_TENANT_ID = '22222222-2222-4222-8222-222222222222'
        $env:ARM_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
        Mock Invoke-TerraformWithRetry { [pscustomobject]@{ success = $true } }
        try {
            $null = Invoke-TerraformInit -terraformModulePath $TestDrive `
                -repoId 'example' -stateStorageAccountName 'storage' -stateContainerName 'tfstate' `
                -stateTenantId '44444444-4444-4444-8444-444444444444' `
                -stateSubscriptionId '55555555-5555-4555-8555-555555555555' `
                -stateClientId '66666666-6666-4666-8666-666666666666' -issueLog @()

            Should -Invoke Invoke-TerraformWithRetry -Exactly 1 -ParameterFilter {
                $argsList = $commands[0].Arguments
                $argsList -contains '-backend-config=tenant_id=44444444-4444-4444-8444-444444444444' -and
                $argsList -contains '-backend-config=subscription_id=55555555-5555-4555-8555-555555555555' -and
                $argsList -contains '-backend-config=client_id=66666666-6666-4666-8666-666666666666' -and
                $argsList -contains '-backend-config=use_azuread_auth=true' -and
                $argsList -contains '-backend-config=use_oidc=true' -and
                $argsList -contains '-backend-config=use_cli=false' -and
                $argsList -contains '-backend-config=use_msi=false' -and
                $argsList -contains '-backend-config=lookup_blob_endpoint=false' -and
                $argsList -contains '-backend-config="key=example.tfstate"' -and
                ($argsList -join ' ') -notmatch 'oidc_token|secret|access_key|sas_token|environment_variable_suffix' -and
                $stateSubscriptionId -eq '55555555-5555-4555-8555-555555555555'
            }
            $env:ARM_CLIENT_ID | Should -Be '11111111-1111-4111-8111-111111111111'
            $env:ARM_TENANT_ID | Should -Be '22222222-2222-4222-8222-222222222222'
            $env:ARM_SUBSCRIPTION_ID | Should -Be '33333333-3333-4333-8333-333333333333'
        }
        finally {
            foreach ($name in $previous.Keys) {
                if ($null -eq $previous[$name]) {
                    Remove-Item -LiteralPath "Env:$name"
                }
                else {
                    Set-Item -LiteralPath "Env:$name" -Value $previous[$name]
                }
            }
        }

    }

    It 'rejects partial backend identity before Terraform runs' {
        Mock Invoke-TerraformWithRetry { throw 'Terraform must not run' }
        {
            Invoke-TerraformInit -terraformModulePath $TestDrive `
                -stateTenantId '44444444-4444-4444-8444-444444444444' -issueLog @()
        } | Should -Throw '*all three*'
        Should -Invoke Invoke-TerraformWithRetry -Exactly 0
    }
}

Describe 'State identity wiring' {
    It 'forwards the state subscription through plan, apply, and both retry commands' {
        $path = Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/lib/TerraformOperations.ps1'
        )
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $function = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-TerraformPlanAndApply'
        }, $true)
        $calls = @($function.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq 'Invoke-TerraformWithRetry'
        }, $true))
        $calls.Count | Should -Be 3
        foreach ($call in $calls) {
            $call.Extent.Text | Should -Match '-stateSubscriptionId \$stateSubscriptionId'
        }
    }

    It 'passes state identity before any repository mutations' {
        $source = Get-Content -LiteralPath (Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/Invoke-RepositorySync.ps1'
        )) -Raw
        $source.IndexOf('Resolve-RepositorySyncStateIdentity') |
            Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
        $source | Should -Match '(?s)Invoke-TerraformInit\s+`.*?-stateTenantId \$stateTenantId'
        $source | Should -Match '(?s)Invoke-TerraformInit\s+`.*?-stateClientId \$stateClientId'
        $source | Should -Match '(?s)Invoke-TerraformPlanAndApply\s+`.*?-stateSubscriptionId \$stateSubscriptionId'
    }

    It 'keeps provider environment while logging the CLI into the state identity' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot (
            '.github/workflows/repository-management-sync.yml'
        )) -Raw
        foreach ($name in 'TENANT', 'SUBSCRIPTION', 'CLIENT') {
            $workflow | Should -Match ('ARM_' + $name + '_ID: \$\{\{ vars\.ARM_' + $name + '_ID \}\}')
            $workflow | Should -Match ('ARM_BACKEND_' + $name + '_ID: \$\{\{ vars\.ARM_BACKEND_' + $name + '_ID \}\}')
        }
        $workflow | Should -Match 'client-id: \$\{\{ steps\.state-identity\.outputs\.client-id \}\}'
        $workflow | Should -Match 'tenant-id: \$\{\{ steps\.state-identity\.outputs\.tenant-id \}\}'
        $workflow | Should -Match 'subscription-id: \$\{\{ steps\.state-identity\.outputs\.subscription-id \}\}'
        $workflow | Should -Match '-stateTenantId \$env:ARM_BACKEND_TENANT_ID'
        $workflow | Should -Match '-stateClientId \$env:ARM_BACKEND_CLIENT_ID'
        $workflow | Should -Match '-stateSubscriptionId \$env:ARM_BACKEND_SUBSCRIPTION_ID'
        $workflow | Should -Not -Match 'ARM_BACKEND_ENVIRONMENT_VARIABLE_SUFFIX|ARM_OIDC_TOKEN:'
        $workflow | Should -Match 'cancel-in-progress: false'
        $workflow | Should -Match "vars\.AVM_SYNC_PAUSED != 'true' \|\| github\.event_name == 'workflow_dispatch'"
    }
}

Describe 'Resolve-RepositorySyncStateIdentity' {
    It 'returns no override when all values are unset' {
        Resolve-RepositorySyncStateIdentity | Should -BeNullOrEmpty
    }

    It 'rejects every partial combination' -ForEach @(
        @{ Tenant = $true; Subscription = $false; Client = $false }
        @{ Tenant = $false; Subscription = $true; Client = $false }
        @{ Tenant = $false; Subscription = $false; Client = $true }
        @{ Tenant = $true; Subscription = $true; Client = $false }
        @{ Tenant = $true; Subscription = $false; Client = $true }
        @{ Tenant = $false; Subscription = $true; Client = $true }
    ) {
        $id = '11111111-1111-4111-8111-111111111111'
        $parameters = @{
            TenantId = $(if ($Tenant) { $id } else { '' })
            SubscriptionId = $(if ($Subscription) { $id } else { '' })
            ClientId = $(if ($Client) { $id } else { '' })
        }
        { Resolve-RepositorySyncStateIdentity @parameters } | Should -Throw '*all three*'
    }

    It 'rejects invalid or empty GUIDs' -ForEach @(
        @{ Value = 'not-a-guid' }
        @{ Value = '00000000-0000-0000-0000-000000000000' }
    ) {
        {
            Resolve-RepositorySyncStateIdentity -TenantId $Value `
                -SubscriptionId '11111111-1111-4111-8111-111111111111' `
                -ClientId '22222222-2222-4222-8222-222222222222'
        } | Should -Throw '*non-empty GUIDs*'
    }
}

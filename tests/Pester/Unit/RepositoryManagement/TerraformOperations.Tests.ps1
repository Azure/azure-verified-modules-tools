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
    BeforeEach {
        $script:initRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:initRoot
        Mock Invoke-RepositorySyncTerraform {}
    }

    It 'uses upgrade for the local backend' {
        $null = Invoke-TerraformInit `
            -terraformModulePath $script:initRoot `
            -repositoryCreationModeEnabled $true `
            -repoId 'example' `
            -orgAndRepoName 'Azure/example' `
            -issueLog @()

        Should -Invoke Invoke-RepositorySyncTerraform -Exactly 1 -ParameterFilter {
            $Arguments -join ' ' -eq 'init -upgrade -input=false -no-color'
        }
    }

    It 'uses upgrade before remote backend configuration arguments' {
        $null = Invoke-TerraformInit `
            -terraformModulePath $script:initRoot `
            -repositoryCreationModeEnabled $false `
            -repoId 'example' `
            -orgAndRepoName 'Azure/example' `
            -stateStorageAccountName 'storage' `
            -stateContainerName 'state' `
            -stateTenantId '44444444-4444-4444-8444-444444444444' `
            -stateSubscriptionId '55555555-5555-4555-8555-555555555555' `
            -stateClientId '66666666-6666-4666-8666-666666666666' `
            -issueLog @()

        Should -Invoke Invoke-RepositorySyncTerraform -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'init' -and $Arguments[1] -eq '-upgrade' -and
            $Arguments -contains '-reconfigure' -and $Arguments -contains '-backend-config=key=example.tfstate'
        }
    }

    It 'rejects missing remote identity instead of using provider discovery' {
        {
            Invoke-TerraformInit -terraformModulePath $script:initRoot `
                -repoId 'example' -stateStorageAccountName 'storage' -stateContainerName 'tfstate' -issueLog @()
        } | Should -Throw '*all five*'
        Should -Invoke Invoke-RepositorySyncTerraform -Exactly 0
    }

    It 'pins only nonsecret backend metadata without changing provider environment' {
        $previous = @{}
        foreach ($name in 'ARM_CLIENT_ID', 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID') {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:ARM_CLIENT_ID = '11111111-1111-4111-8111-111111111111'
        $env:ARM_TENANT_ID = '22222222-2222-4222-8222-222222222222'
        $env:ARM_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
        try {
            $null = Invoke-TerraformInit -terraformModulePath $script:initRoot `
                -repoId 'example' -stateStorageAccountName 'storage' -stateContainerName 'tfstate' `
                -stateTenantId '44444444-4444-4444-8444-444444444444' `
                -stateSubscriptionId '55555555-5555-4555-8555-555555555555' `
                -stateClientId '66666666-6666-4666-8666-666666666666' -issueLog @()

            Should -Invoke Invoke-RepositorySyncTerraform -Exactly 1 -ParameterFilter {
                $argsList = $Arguments
                $argsList -contains '-backend-config=tenant_id=44444444-4444-4444-8444-444444444444' -and
                $argsList -contains '-backend-config=subscription_id=55555555-5555-4555-8555-555555555555' -and
                $argsList -contains '-backend-config=client_id=66666666-6666-4666-8666-666666666666' -and
                $argsList -contains '-backend-config=use_azuread_auth=true' -and
                $argsList -contains '-backend-config=use_oidc=true' -and
                $argsList -contains '-backend-config=use_cli=false' -and
                $argsList -contains '-backend-config=use_msi=false' -and
                $argsList -contains '-backend-config=lookup_blob_endpoint=false' -and
                $argsList -contains '-backend-config=key=example.tfstate' -and
                ($argsList -join ' ') -notmatch 'resource_group_name|oidc_token|secret|access_key|sas_token|environment_variable_suffix'
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

    It 'rejects partial backend configuration before Terraform runs' {
        {
            Invoke-TerraformInit -terraformModulePath $script:initRoot `
                -stateTenantId '44444444-4444-4444-8444-444444444444' -issueLog @()
        } | Should -Throw '*all five*'
        Should -Invoke Invoke-RepositorySyncTerraform -Exactly 0
    }
}

Describe 'State identity wiring' {
    It 'starts ordinary previews and applies directly after matrix generation' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot (
            '.github/workflows/repository-management-sync.yml'
        )) -Raw
        $jobs = [regex]::Match($workflow, '(?ms)^jobs:\r?\n(?<jobs>.*)$')
        $jobs.Success | Should -BeTrue
        @([regex]::Matches($jobs.Groups['jobs'].Value, '(?m)^  ([a-z][a-z0-9-]+):\r?$') |
            ForEach-Object { $_.Groups[1].Value }) | Should -Be @('generate-matrix', 'sync-repository')
        $worker = [regex]::Match($jobs.Value, '(?ms)^  sync-repository:\r?\n(?<header>.*?)^    uses:')
        $worker.Success | Should -BeTrue
        $dependencies = [regex]::Matches($worker.Groups['header'].Value, '(?m)^    needs: (.+)\r?$')
        $dependencies | Should -HaveCount 1
        $dependencies[0].Groups[1].Value.Trim() | Should -BeExactly 'generate-matrix'
        $worker.Groups['header'].Value | Should -Match "(?m)^    if: needs.generate-matrix.result == 'success'"
        $workflow | Should -Match '(?m)^    uses: \./\.github/workflows/repository-management-sync-repository\.yml'
        $worker.Groups['header'].Value | Should -Match 'include: \$\{\{ fromJson\(needs\.generate-matrix\.outputs\.matrix\) \}\}'
        $workflow | Should -Match '(?m)^  group: repository-sync\r?$'
        $workflow | Should -Match '(?m)^  cancel-in-progress: false\r?$'
        $dispatch = [regex]::Match($workflow, '(?ms)^  workflow_dispatch:\r?\n.*?(?=^  \S|\z)')
        $dispatch.Success | Should -BeTrue
        $planOnly = [regex]::Match($dispatch.Value, '(?ms)^      plan_only:\r?\n.*?(?=^      \S|\z)')
        $planOnly.Success | Should -BeTrue
        $planOnly.Value | Should -Match '(?m)^        default: true\r?$'
        $planOnly.Value | Should -Match '(?m)^        type: boolean\r?$'
        @([regex]::Matches($dispatch.Value, '(?m)^      ([a-z][a-z0-9_]+):\r?$') |
            ForEach-Object { $_.Groups[1].Value }) | Should -Be @(
            'repositories', 'repositories_to_skip', 'plan_only', 'use_workflow_authoring_source', 'force_file_update',
            'sync_project_items', 'include_closed_project_items', 'project_lookback_days'
        )
    }

    It 'plans, privately reads, and applies one guarded plan without legacy retries or state rewrites' {
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
            $node.GetCommandName() -eq 'Invoke-RepositorySyncTerraform'
        }, $true))
        $calls.Count | Should -Be 3
        foreach ($call in $calls) {
            $call.Extent.Text | Should -Match '-Environment \$environment'
        }
        $function.Extent.Text | Should -Match 'Assert-AvmRepositorySyncPlan'
        $function.Extent.Text | Should -Not -Match 'Invoke-TerraformWithRetry|force-unlock|state (rm|mv|push)|Start-Process'
    }

    It 'requires complete state configuration before any repository mutations' {
        $source = Get-Content -LiteralPath (Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/Invoke-RepositorySync.ps1'
        )) -Raw
        $validationIndex = $source.IndexOf('Resolve-RepositorySyncStateConfiguration')
        $validationIndex | Should -BeGreaterThan 0
        $validationIndex | Should -BeLessThan $source.IndexOf('Clear-TerraformWorkspace')
        $validationIndex |
            Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
        $source | Should -Match '(?s)Invoke-TerraformInit\s+`.*?-stateTenantId \$stateTenantId'
        $source | Should -Match '(?s)Invoke-TerraformInit\s+`.*?-stateClientId \$stateClientId'
        $source.IndexOf('Invoke-TerraformPlanAndApply') | Should -BeLessThan $source.IndexOf('Remove-LegacyBranchProtection')
    }

    It 'uses backend-only CLI recovery authentication without changing provider OIDC' {
        $workflow = Get-Content -LiteralPath (Join-Path $script:repoRoot (
            '.github/workflows/repository-management-sync-repository.yml'
        )) -Raw
        $dispatcher = Get-Content -LiteralPath (Join-Path $script:repoRoot (
            '.github/workflows/repository-management-sync.yml'
        )) -Raw
        $syncStep = [regex]::Match(
            $workflow,
            '(?ms)^      - name: Run sync for .*?(?=^      - name:)'
        ).Value
        $syncStep | Should -Not -BeNullOrEmpty
        $workflow | Should -Match '(?s)Write-Host "Running repo sync"\s+\$moduleToLoad = .*?Import-Module -Name \$moduleToLoad -Force -ErrorAction Stop\s+\./scripts/Invoke-RepositorySync\.ps1'
        $worker = [regex]::Match($workflow, '(?ms)^  run-sync:.*?(?=^  [a-z][a-z0-9-]+:|\z)').Value
        $worker | Should -Not -BeNullOrEmpty
        foreach ($name in 'TENANT', 'SUBSCRIPTION', 'CLIENT') {
            $worker | Should -Not -Match ('(?m)^\s*ARM_' + $name + '_ID:\s*')
            $workflow | Should -Match ('ARM_BACKEND_' + $name + '_ID: \$\{\{ vars\.ARM_BACKEND_' + $name + '_ID \}\}')
        }
        foreach ($name in @('TEST_BAMI_TENANT_ID', 'TEST_BAMI_CONTROLLER_CLIENT_ID', 'TEST_BAMI_ADMIN_SUBSCRIPTION_ID')) {
            $syncStep | Should -Match ($name + ': \$\{\{ vars\.' + $name + ' \}\}')
            $syncStep | Should -Match ($name + '\s*=\s*\$env:' + $name + '\b')
        }
        $syncStep | Should -Match '-bamiSettings \$bamiSettings'
        $syncStep | Should -Not -Match '-(?:managementGroupId|testSubscriptionIds|identityResourceGroupName)\b'
        $worker | Should -Not -Match 'gh auth login'
        $login = [regex]::Match($worker, '(?ms)^      - name: Sign in with the state backend identity\r?\n.*?(?=^      - name:)').Value
        $login | Should -Match 'uses: azure/login@7ddb5af1ef8758cf1353cf3b42f940aee27ba21c'
        foreach ($name in @('tenant', 'subscription', 'client')) {
            $login | Should -Match ($name + '-id: \$\{\{ steps\.state-backend\.outputs\.' + $name + '-id \}\}')
        }
        $login | Should -Not -Match 'TEST_BAMI|secrets\.|ARM_OIDC_TOKEN'
        @([regex]::Matches($worker, 'uses: azure/login@')) | Should -HaveCount 1
        $worker | Should -Match '(?m)^      actions: read\r?$'
        $worker | Should -Match '(?m)^      contents: read\r?$'
        $worker | Should -Match '(?m)^      id-token: write\r?$'
        $syncStep | Should -Match 'ACTIONS_STATE_LOCK_TOKEN: \$\{\{ github\.token \}\}'
        $caller = [regex]::Match($dispatcher, '(?ms)^  sync-repository:.*$').Value
        foreach ($permission in @('actions: read', 'contents: read', 'id-token: write')) {
            $caller | Should -Match ('(?m)^      ' + [regex]::Escape($permission) + '\r?$')
        }
        $workflow | Should -Match '-stateTenantId \$env:ARM_BACKEND_TENANT_ID'
        $workflow | Should -Match '-stateClientId \$env:ARM_BACKEND_CLIENT_ID'
        $workflow | Should -Match '-stateSubscriptionId \$env:ARM_BACKEND_SUBSCRIPTION_ID'
        $workflow | Should -Match '-stateStorageAccountName \$env:ARM_BACKEND_STORAGE_ACCOUNT_NAME'
        $workflow | Should -Match '-stateContainerName \$env:ARM_BACKEND_STORAGE_CONTAINER_NAME'
        $workflow | Should -Match 'ARM_BACKEND_STORAGE_ACCOUNT_NAME: \$\{\{ vars\.ARM_BACKEND_STORAGE_ACCOUNT_NAME \}\}'
        $workflow | Should -Match 'ARM_BACKEND_STORAGE_CONTAINER_NAME: \$\{\{ vars\.ARM_BACKEND_STORAGE_CONTAINER_NAME \}\}'
        $workflow | Should -Match 'ARM_BACKEND_STORAGE_ACCOUNT_NAME: \$\{\{ steps\.state-backend\.outputs\.storage-account \}\}'
        $workflow | Should -Match 'ARM_BACKEND_STORAGE_CONTAINER_NAME: \$\{\{ steps\.state-backend\.outputs\.container \}\}'
        $workflow | Should -Not -Match 'stateResourceGroupName|STORAGE_ACCOUNT_RESOURCE_GROUP_NAME'
        $workflow | Should -Not -Match '(?<![A-Z_])STORAGE_ACCOUNT_(CONTAINER_)?NAME'
        $workflow | Should -Not -Match 'ARM_BACKEND_ENVIRONMENT_VARIABLE_SUFFIX|ARM_OIDC_TOKEN:'
        $dispatcher | Should -Match 'cancel-in-progress: false'
        $workflow | Should -Not -Match 'AVM_SYNC_PAUSED'
    }

    It 'pins the sole provider root to BAMI values without state-identity fallback' {
        $providerRoots = @(
            @{
                Path = Join-Path $script:repoRoot 'repository-management' 'repository-sync' 'terraform' 'terraform.tf'
                Tenant = 'var.bami_test_settings == null ? null : var.bami_test_settings.tenant_id'
                Subscription = 'var.bami_test_settings == null ? null : var.bami_test_settings.admin_subscription_id'
                Client = 'var.bami_test_settings == null ? null : var.bami_test_settings.controller_client_id'
            }
        )
        foreach ($root in $providerRoots) {
            $configuration = Get-Content -LiteralPath $root.Path -Raw
            foreach ($name in @('azapi', 'azuread')) {
                $provider = [regex]::Match(
                    $configuration,
                    '(?ms)^provider "' + $name + '" \{.*?^\}'
                ).Value
                $provider | Should -Not -BeNullOrEmpty
                $provider | Should -Match ('(?m)^\s*tenant_id\s*=\s*' + [regex]::Escape($root.Tenant) + '\s*$')
                $provider | Should -Match ('(?m)^\s*client_id\s*=\s*' + [regex]::Escape($root.Client) + '\s*$')
                if ($name -eq 'azapi') {
                    $provider | Should -Match ('(?m)^\s*subscription_id\s*=\s*' + [regex]::Escape($root.Subscription) + '\s*$')
                }
                $provider | Should -Match '(?m)^\s*use_oidc\s*=\s*true\s*$'
                $provider | Should -Match '(?m)^\s*use_cli\s*=\s*false\s*$'
                $provider | Should -Match '(?m)^\s*use_msi\s*=\s*false\s*$'
                $provider | Should -Not -Match 'ARM_BACKEND_|state-backend|var\.state_'
            }
        }
    }

    It 'removes the runtime resource-group parameter from both script surfaces' {
        (Get-Command Invoke-TerraformInit).Parameters.Keys | Should -Not -Contain 'stateResourceGroupName'
        $source = Get-Content -LiteralPath (Join-Path $script:repoRoot (
            'repository-management/repository-sync/scripts/Invoke-RepositorySync.ps1'
        )) -Raw
        $source | Should -Not -Match 'stateResourceGroupName'
    }
}

Describe 'Resolve-RepositorySyncStateConfiguration' {
    BeforeEach {
        $script:backend = @{
            TenantId = '44444444-4444-4444-8444-444444444444'
            SubscriptionId = '55555555-5555-4555-8555-555555555555'
            ClientId = '66666666-6666-4666-8666-666666666666'
            StorageAccountName = 'tmestorage'
            ContainerName = 'tme-state'
        }
    }

    It 'selects the complete backend without modifying the supplied settings' {
        $original = $script:backend.Clone()
        $selected = Resolve-RepositorySyncStateConfiguration -Backend $script:backend
        foreach ($key in $script:backend.Keys) {
            $selected.$key | Should -Be $script:backend[$key]
            $script:backend[$key] | Should -Be $original[$key]
        }
    }

    It 'does not accept a legacy configuration source' {
        (Get-Command Resolve-RepositorySyncStateConfiguration).Parameters.Keys | Should -Not -Contain 'Legacy'
    }

    It 'rejects every incomplete configuration instead of mixing tenants or accounts' {
        $names = @('TenantId', 'SubscriptionId', 'ClientId', 'StorageAccountName', 'ContainerName')
        foreach ($mask in 0..30) {
            $partial = @{}
            foreach ($index in 0..4) {
                if ($mask -band (1 -shl $index)) {
                    $partial[$names[$index]] = $script:backend[$names[$index]]
                }
            }
            { Resolve-RepositorySyncStateConfiguration -Backend $partial } |
                Should -Throw '*all five*'
        }
    }

    It 'rejects blank values for each backend field' -ForEach @(
        @{ Value = $null }
        @{ Value = '' }
        @{ Value = ' ' }
    ) {
        foreach ($key in $script:backend.Keys) {
            $partial = $script:backend.Clone()
            $partial[$key] = $Value
            { Resolve-RepositorySyncStateConfiguration -Backend $partial } | Should -Throw '*all five*'
        }
    }

    It 'rejects invalid storage names' -ForEach @(
        @{ Key = 'StorageAccountName'; Value = 'UpperCaseAccount'; Message = '*state storage account*' }
        @{ Key = 'StorageAccountName'; Value = 'too-long-storage-account-name'; Message = '*state storage account*' }
        @{ Key = 'ContainerName'; Value = '-leading-hyphen'; Message = '*state container*' }
        @{ Key = 'ContainerName'; Value = 'double--hyphen'; Message = '*state container*' }
        @{ Key = 'ContainerName'; Value = 'state/path'; Message = '*state container*' }
    ) {
        $script:backend[$Key] = $Value
        { Resolve-RepositorySyncStateConfiguration -Backend $script:backend } |
            Should -Throw $Message
    }

    It 'rejects invalid identity values even with complete storage configuration' {
        $script:backend.ClientId = 'not-a-guid'
        { Resolve-RepositorySyncStateConfiguration -Backend $script:backend } |
            Should -Throw '*non-empty GUIDs*'
    }
}

Describe 'State backend workflow resolution' {
    It 'resolves the actual workflow script without mixing configurations' -ForEach @(
        @{ Mode = 'backend' }
        @{ Mode = 'legacy' }
        @{ Mode = 'missing' }
        @{ Mode = 'partial' }
    ) {
        $workflow = Get-Content -Raw (Join-Path $script:repoRoot '.github/workflows/repository-management-sync-repository.yml')
        $step = [regex]::Match($workflow, '(?ms)^      - name: Resolve state backend\r?\n.*?^        run: \|\r?\n(?<body>.*?)(?=^      - name:)')
        $step.Success | Should -BeTrue
        $bindings = @([regex]::Matches($step.Value, '(?m)^          ([A-Z_]+): \$\{\{ vars\.\1 \}\}') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $bindings | Should -Be @(
            'ARM_BACKEND_CLIENT_ID', 'ARM_BACKEND_STORAGE_ACCOUNT_NAME', 'ARM_BACKEND_STORAGE_CONTAINER_NAME',
            'ARM_BACKEND_SUBSCRIPTION_ID', 'ARM_BACKEND_TENANT_ID'
        )
        $body = [regex]::Replace($step.Groups['body'].Value, '(?m)^          ', '')
        $resolve = [scriptblock]::Create($body)
        $variables = @{
            ARM_TENANT_ID = '11111111-1111-4111-8111-111111111111'
            ARM_SUBSCRIPTION_ID = '22222222-2222-4222-8222-222222222222'
            ARM_CLIENT_ID = '33333333-3333-4333-8333-333333333333'
            STORAGE_ACCOUNT_NAME = ''
            STORAGE_ACCOUNT_CONTAINER_NAME = ''
            ARM_BACKEND_TENANT_ID = ''
            ARM_BACKEND_SUBSCRIPTION_ID = ''
            ARM_BACKEND_CLIENT_ID = ''
            ARM_BACKEND_STORAGE_ACCOUNT_NAME = ''
            ARM_BACKEND_STORAGE_CONTAINER_NAME = ''
            GITHUB_OUTPUT = Join-Path $TestDrive "$Mode-outputs.txt"
        }
        if ($Mode -eq 'legacy') {
            $variables.STORAGE_ACCOUNT_NAME = 'originalstorage'
            $variables.STORAGE_ACCOUNT_CONTAINER_NAME = 'original-state'
        }
        if ($Mode -in @('backend', 'partial')) {
            $variables.ARM_BACKEND_TENANT_ID = '44444444-4444-4444-8444-444444444444'
            $variables.ARM_BACKEND_SUBSCRIPTION_ID = '55555555-5555-4555-8555-555555555555'
            $variables.ARM_BACKEND_CLIENT_ID = '66666666-6666-4666-8666-666666666666'
            $variables.ARM_BACKEND_STORAGE_ACCOUNT_NAME = 'tmestorage'
            if ($Mode -eq 'backend') {
                $variables.ARM_BACKEND_STORAGE_CONTAINER_NAME = 'tme-state'
            }
        }
        $previous = @{}
        foreach ($name in $variables.Keys) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        Push-Location (Join-Path $script:repoRoot 'repository-management/repository-sync')
        try {
            foreach ($name in $variables.Keys) {
                [Environment]::SetEnvironmentVariable($name, $variables[$name])
            }
            if ($Mode -ne 'backend') {
                { & $resolve } | Should -Throw '*all five*'
                Test-Path -LiteralPath $variables.GITHUB_OUTPUT | Should -BeFalse
            }
            else {
                & $resolve
                $output = Get-Content -LiteralPath $variables.GITHUB_OUTPUT
                $output.Count | Should -Be 5
                $output | Should -Contain "tenant-id=$($variables.ARM_BACKEND_TENANT_ID)"
                $output | Should -Contain "subscription-id=$($variables.ARM_BACKEND_SUBSCRIPTION_ID)"
                $output | Should -Contain "client-id=$($variables.ARM_BACKEND_CLIENT_ID)"
                $output | Should -Contain 'storage-account=tmestorage'
                $output | Should -Contain 'container=tme-state'
            }
            foreach ($name in 'ARM_TENANT_ID', 'ARM_SUBSCRIPTION_ID', 'ARM_CLIENT_ID') {
                [Environment]::GetEnvironmentVariable($name) | Should -Be $variables[$name]
            }
        }
        finally {
            Pop-Location
            foreach ($name in $previous.Keys) {
                [Environment]::SetEnvironmentVariable($name, $previous[$name])
            }
        }
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

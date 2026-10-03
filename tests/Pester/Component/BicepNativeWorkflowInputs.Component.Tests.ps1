#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1')
    . (Join-Path $PSScriptRoot '..' 'Helpers' 'BicepNativeWorkflow.ps1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Component: Bicep native workflow CI and parameter inputs' -Tag Component {
    BeforeEach {
        $script:fixture = New-NativeBicepWorkflowFixture -TestRoot $TestDrive
        $script:options = Get-NativeBicepWorkflowOptions -Fixture $script:fixture
        $script:environment = @{}
        foreach ($name in @('AVM_CI_VARIABLES', 'AVM_CI_SECRETS', 'CI_KEY_VAULT_NAME',
                'TOKEN_NAMEPREFIX', 'localToken_workflowExample', 'VALIDATE_SUBSCRIPTION_ID',
                'VALIDATE_TENANT_ID', 'TEST_SUBSCRIPTION_IDS')) {
            $script:environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
    }
    AfterEach {
        foreach ($name in $script:environment.psbase.Keys) {
            $value = $script:environment[$name]
            if ($null -eq $value) { $value = [NullString]::Value }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
        Remove-NativeBicepWorkflowFixture -Fixture $script:fixture
    }

    It 'ignores ambient CI inputs unless explicitly enabled and never echoes malformed secret JSON' {
        $env:AVM_CI_SECRETS = 'invalid-do-not-echo-secret'
        (Invoke-AvmTestE2e @script:options).Status | Should -Be 'pass'
        $script:fixture.Calls.Clear()
        $failure = $null
        try { Invoke-AvmTestE2e @script:options -UseCiInputs } catch { $failure = $_ }
        $failure | Should -Not -BeNullOrEmpty
        $failure.Exception.Message | Should -Match 'AVM_CI_SECRETS must contain a JSON object'
        $failure.Exception.Message | Should -Not -Match 'do-not-echo-secret'
        $script:fixture.Calls.Count | Should -Be 0
    }

    It 'merges typed secret winners, literal CI names, secure values, keys and count without persisting values' {
        $script:fixture.Parameters['keys'] = @{ type = 'array' }
        $script:fixture.Parameters['count'] = @{ type = 'int' }
        $script:fixture.Parameters['is_enabled'] = @{ type = 'bool' }
        $script:fixture.Parameters['secretValue'] = @{ type = 'secureString' }
        $script:fixture.Parameters['settings'] = @{ '$ref' = '#/definitions/settings' }
        $script:fixture.Definitions['settings'] = @{ type = 'object' }
        $env:AVM_CI_VARIABLES = @{
            CI_COUNT = 'invalid-unused-integer'; CI_KEYS = '["one"]'
            CI__is_enabled = 'false'; CI_SETTINGS = '{"keys":["#_subscriptionId_#"],"region":"#_resourceLocation_#"}'
        } | ConvertTo-Json -Compress
        $env:AVM_CI_SECRETS = @{ CI_COUNT = '0'; CI_SECRET_VALUE = 'do-not-persist-secret' } | ConvertTo-Json -Compress
        $result = Invoke-AvmTestE2e @script:options -UseCiInputs
        $result.Status | Should -Be 'pass'
        foreach ($inputRecord in $script:fixture.NativeInputs) {
            ($inputRecord.Parameters['keys'] -is [object[]]) | Should -BeTrue
            $inputRecord.Parameters['keys'].Count | Should -Be 1
            $inputRecord.Parameters['keys'][0] | Should -BeExactly 'one'
            $inputRecord.Parameters['count'] | Should -Be 0
            $inputRecord.Parameters['is_enabled'] | Should -BeFalse
            $inputRecord.Parameters['secretValue'] | Should -BeOfType ([Security.SecureString])
            $inputRecord.Parameters['settings']['keys'][0] | Should -Be $script:options.SubscriptionId
            $inputRecord.Parameters['settings']['region'] | Should -Be 'eastus'
        }
        (Get-Content -LiteralPath $script:fixture.StatePath -Raw) |
            Should -Not -Match 'do-not-persist-secret|invalid-unused-integer|secretValue|settings'
        ($result | ConvertTo-Json -Depth 20) | Should -Not -Match 'do-not-persist-secret'
    }

    It 'selects explicit parameters before trying to convert unused CI values' {
        $script:fixture.Parameters['count'] = @{ type = 'int' }
        $env:AVM_CI_VARIABLES = '{"CI_COUNT":"invalid-unused-integer"}'
        $script:options.Parameters = @{ count = 0 }
        (Invoke-AvmTestE2e @script:options -UseCiInputs).Status | Should -Be 'pass'
        $script:fixture.NativeInputs[-1].Parameters['count'] | Should -Be 0
    }

    It 'preserves file vault references separately from ordinary objects containing reference keys' {
        $script:fixture.Parameters['password'] = @{ type = 'secureString' }
        $script:fixture.Parameters['settings'] = @{ type = 'object' }
        $script:fixture.Parameters['count'] = @{ type = 'int' }
        $path = Join-Path $script:fixture.Root 'parameters.json'
        $json = @{
            parameters = @{
                password = @{ reference = @{
                        keyVault = @{ id = '/subscriptions/#_subscriptionId_#/resourceGroups/test/providers/Microsoft.KeyVault/vaults/source' }
                        secretName = 'test-password'
                    } }
                settings = @{ value = @{ reference = 'literal-object-member'; keys = @(); nested = @(, @('#_resourceLocation_#')) } }
                count = @{ value = 0 }
            }
        } | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($path, $json)
        $before = [IO.File]::ReadAllBytes($path)
        $env:AVM_CI_VARIABLES = '{"CI_COUNT":"invalid-unused-integer","CI_SETTINGS":"invalid-unused-object"}'
        $script:options.ParameterFile = $path
        (Invoke-AvmTestE2e @script:options -UseCiInputs).Status | Should -Be 'pass'
        $parameters = $script:fixture.NativeInputs[-1].Parameters
        $parameters['password'] | Should -BeOfType ([hashtable])
        $parameters['password']['reference']['keyVault']['id'] |
            Should -Be "/subscriptions/$($script:options.SubscriptionId)/resourceGroups/test/providers/Microsoft.KeyVault/vaults/source"
        $parameters['settings'] | Should -BeOfType ([Collections.Specialized.OrderedDictionary])
        $parameters['settings']['reference'] | Should -BeExactly 'literal-object-member'
        ($parameters['settings']['keys'] -is [object[]]) | Should -BeTrue
        $parameters['settings']['keys'].Count | Should -Be 0
        ($parameters['settings']['nested'][0] -is [object[]]) | Should -BeTrue
        $parameters['settings']['nested'][0][0] | Should -Be 'eastus'
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }

    It 'uses CI tokens in temporary templates and nested parameters without rewriting source' {
        $env:TOKEN_NAMEPREFIX = 'workflow-prefix'
        $env:localToken_workflowExample = 'from-local-token'
        $script:options.Parameters = @{
            nested = @{ keys = @('#_workflowExample_#'); name = '#_namePrefix_#'; region = '#_resourceLocation_#' }
        }
        (Invoke-AvmTestE2e @script:options -UseCiInputs).Status | Should -Be 'pass'
        $inputRecord = $script:fixture.NativeInputs[-1]
        ($inputRecord.Content | ConvertFrom-Json).resources[0].name | Should -BeExactly 'workflow-prefix'
        $inputRecord.Parameters['nested']['keys'][0] | Should -BeExactly 'from-local-token'
        $inputRecord.Parameters['nested']['name'] | Should -BeExactly 'workflow-prefix'
        $inputRecord.Parameters['nested']['region'] | Should -BeExactly 'eastus'
        (Get-Content -LiteralPath (Join-Path $script:fixture.Directory 'main.test.bicep') -Raw) |
            Should -Match '#_namePrefix_#'
    }

    It 'chooses an eligible unpinned group region and uses it consistently for the group and deployment' {
        $script:options.Remove('ResourceLocation')
        (Invoke-AvmTestE2e @script:options).Status | Should -Be 'pass'
        @($script:fixture.GroupLocations) | Should -Be @('eastus')
        $script:fixture.GroupAbsenceChecks | Should -BeGreaterThan 0
        @($script:fixture.NativeInputs | ForEach-Object { $_.Parameters['resourceLocation'] } |
            Select-Object -Unique) | Should -Be @('eastus')
    }

    It 'rejects conflicting location pins before creating a group or submitting a deployment' {
        $script:options.Parameters = @{ resourceLocation = 'centralus' }
        $result = Invoke-AvmTestE2e @script:options
        $result.Status | Should -Be 'fail'
        ($result.Issues.Message -join ' ') | Should -Match 'Conflicting resource locations'
        $script:fixture.Calls | Should -Not -Contain 'group-create'
        $script:fixture.Calls | Should -Not -Contain 'create'
    }

    It 'uses explicit identity instead of an ambient CI pool' {
        $env:VALIDATE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000003'
        $env:VALIDATE_TENANT_ID = '00000000-0000-0000-0000-000000000004'
        $env:TEST_SUBSCRIPTION_IDS = '[{"id":"00000000-0000-0000-0000-000000000005","name":"ambient"}]'
        (Invoke-AvmTestE2e @script:options -UseCiInputs).Status | Should -Be 'pass'
        @($script:fixture.NativeInputs | ForEach-Object SubscriptionId | Select-Object -Unique) |
            Should -Be @($script:options.SubscriptionId)
    }

    It 'balances multiple cases over the opted-in subscription pool and retains one state file per case' {
        foreach ($name in @('second', 'third', 'fourth')) {
            $directory = Join-Path $script:fixture.Root 'tests' 'e2e' $name
            $null = New-Item -ItemType Directory -Path $directory
            Set-Content -LiteralPath (Join-Path $directory 'main.test.bicep') -Value 'param name string'
        }
        $script:fixture.StatePath = ''
        $script:options.Remove('CleanupStatePath')
        $script:options.Remove('SubscriptionId')
        $script:options.Remove('TenantId')
        $env:VALIDATE_TENANT_ID = '00000000-0000-0000-0000-000000000002'
        $env:TEST_SUBSCRIPTION_IDS = '[{"id":"00000000-0000-0000-0000-000000000003","name":"second"},{"id":"00000000-0000-0000-0000-000000000001","name":"first"}]'
        $result = Invoke-AvmTestE2e @script:options -UseCiInputs -SubscriptionSelectionSeed 42
        $result.Status | Should -Be 'pass'
        $result.CleanupStatePaths.Count | Should -Be 4
        $selected = @($script:fixture.NativeInputs | Where-Object Operation -EQ 'Create' | Group-Object SubscriptionId)
        $selected.Count | Should -Be 2
        @($selected | ForEach-Object Count | Sort-Object -Unique) | Should -Be @(2)
        foreach ($path in $result.CleanupStatePaths) {
            (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).status | Should -Be 'Complete'
        }
    }

    It 'rejects a whitespace-only subscription pool before tool or Azure activity' {
        { Invoke-AvmTestE2e @script:options -TestSubscriptionIds ' ' } | Should -Throw -ExpectedMessage '*subscription pool*'
        $script:fixture.Calls.Count | Should -Be 0
    }
}

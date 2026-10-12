#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Bicep native workflow environment opt-in' {
    BeforeEach {
        $script:savedEnvironment = @{}
        $names = @('AVM_CI_VARIABLES', 'AVM_CI_SECRETS', 'TOKEN_NAMEPREFIX',
            'TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID',
            'VALIDATE_TENANT_ID', 'VALIDATE_MANAGEMENT_GROUP_ID', 'ARM_TENANT_ID', 'ARM_MGMTGROUP_ID', 'CI_KEY_VAULT_NAME',
            'localToken_AvmInputFixture', 'localToken_namePrefix')
        foreach ($name in $names) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process')
        }
    }
    AfterEach {
        foreach ($name in $script:savedEnvironment.psbase.Keys) {
            $value = if ($null -eq $script:savedEnvironment[$name]) { [NullString]::Value } else { $script:savedEnvironment[$name] }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }

    It 'ignores ambient CI data and identity without explicit opt-in' {
        $env:AVM_CI_SECRETS = 'malformed-sensitive-canary'
        $env:VALIDATE_SUBSCRIPTION_ID = 'ambient-identity'
        InModuleScope Avm.Authoring {
            $result = Get-AvmBicepWorkflowEnvironment
            $result.Secrets.psbase.Count | Should -Be 0
            $result.Variables.psbase.Count | Should -Be 0
            $result.Tokens.psbase.Count | Should -Be 0
            $result.SubscriptionId | Should -BeExactly ''
        }
    }

    It 'keeps variables and secrets distinct and preserves typed values and literal names' {
        $env:AVM_CI_VARIABLES = '{"CI_COUNT":0,"CI__with_underscore":false,"unrelated":["one"]}'
        $env:AVM_CI_SECRETS = '{"CI_COUNT":7}'
        $env:localToken_AvmInputFixture = 'fixture-value'
        $env:TOKEN_NAMEPREFIX = 'fallback-prefix'
        $env:TEST_SUBSCRIPTION_IDS = '[{"id":"fixture","name":"pool"}]'
        $env:VALIDATE_SUBSCRIPTION_ID = 'explicit-fixture-subscription'
        $env:VALIDATE_TENANT_ID = 'explicit-fixture-tenant'
        $env:CI_KEY_VAULT_NAME = 'fixture-vault'
        InModuleScope Avm.Authoring {
            $result = Get-AvmBicepWorkflowEnvironment -Enabled
            $result.Variables['CI_COUNT'] | Should -Be 0
            $result.Variables['CI__with_underscore'] | Should -BeFalse
            $result.Variables['unrelated'] | Should -Be @('one')
            $result.Secrets['CI_COUNT'] | Should -Be 7
            $result.Tokens['AvmInputFixture'] | Should -BeExactly 'fixture-value'
            $result.Tokens['namePrefix'] | Should -BeExactly 'fallback-prefix'
            $result.PoolJson | Should -BeExactly '[{"id":"fixture","name":"pool"}]'
            $result.SubscriptionId | Should -BeExactly 'explicit-fixture-subscription'
            $result.TenantId | Should -BeExactly 'explicit-fixture-tenant'
            $result.KeyVaultName | Should -BeExactly 'fixture-vault'
        }
    }

    It 'prefers an explicit local name prefix to the workflow fallback' {
        $env:localToken_namePrefix = 'local-prefix'
        $env:TOKEN_NAMEPREFIX = 'fallback-prefix'
        InModuleScope Avm.Authoring {
            (Get-AvmBicepWorkflowEnvironment -Enabled).Tokens['namePrefix'] | Should -BeExactly 'local-prefix'
        }
    }

    It 'matches registry pool precedence at position <Position>' -ForEach @(
        @{ Position = 0 }
        @{ Position = 1 }
        @{ Position = 2 }
        @{ Position = 3 }
    ) {
        $variables = [ordered]@{ VALIDATE_SUBSCRIPTION_IDS = 'canonical-variable'; TEST_SUBSCRIPTION_IDS = 'legacy-variable' }
        $secrets = [ordered]@{ VALIDATE_SUBSCRIPTION_IDS = 'canonical-secret'; TEST_SUBSCRIPTION_IDS = 'legacy-secret' }
        $expected = @('canonical-variable', 'legacy-variable', 'canonical-secret', 'legacy-secret')[$Position]
        if ($Position -gt 0) { $variables['VALIDATE_SUBSCRIPTION_IDS'] = '' }
        if ($Position -gt 1) { $variables['TEST_SUBSCRIPTION_IDS'] = '' }
        if ($Position -gt 2) { $secrets['VALIDATE_SUBSCRIPTION_IDS'] = '' }
        $env:AVM_CI_VARIABLES = ConvertTo-Json -InputObject $variables -Compress
        $env:AVM_CI_SECRETS = ConvertTo-Json -InputObject $secrets -Compress
        $env:VALIDATE_SUBSCRIPTION_IDS = 'resolved-environment-fallback'
        InModuleScope Avm.Authoring -Parameters @{ Expected = $expected } {
            param($Expected)
            (Get-AvmBicepWorkflowEnvironment -Enabled).PoolJson | Should -BeExactly $Expected
        }
    }

    It 'prefers the canonical environment pool to its historical alias' {
        $env:VALIDATE_SUBSCRIPTION_IDS = 'canonical'
        $env:TEST_SUBSCRIPTION_IDS = 'legacy'
        InModuleScope Avm.Authoring {
            (Get-AvmBicepWorkflowEnvironment -Enabled).PoolJson | Should -BeExactly 'canonical'
        }
    }

    It 'uses VALIDATE identity variables before secrets and never substitutes an ARM tenant' {
        $env:AVM_CI_VARIABLES = '{"VALIDATE_TENANT_ID":"variable-tenant","VALIDATE_MANAGEMENT_GROUP_ID":"variable-group"}'
        $env:AVM_CI_SECRETS = '{"VALIDATE_TENANT_ID":"secret-tenant"}'
        $env:ARM_TENANT_ID = 'legacy-arm-tenant'
        InModuleScope Avm.Authoring {
            $ci = Get-AvmBicepWorkflowEnvironment -Enabled
            $ci.TenantId | Should -BeExactly 'variable-tenant'
            $ci.ManagementGroupId | Should -BeExactly 'variable-group'
        }
        $env:AVM_CI_VARIABLES = '{}'
        $env:AVM_CI_SECRETS = '{}'
        InModuleScope Avm.Authoring {
            (Get-AvmBicepWorkflowEnvironment -Enabled).TenantId | Should -BeExactly ''
        }
    }

    It 'accepts complete customer fork settings without requiring a BAMI-published inventory' {
        $pool = ConvertTo-Json -InputObject @(
            @{ id = '44444444-4444-4444-8444-444444444444'; name = 'customer-test' }
        ) -Compress
        $env:AVM_CI_VARIABLES = @{
            VALIDATE_CLIENT_ID = '11111111-1111-4111-8111-111111111111'
            VALIDATE_TENANT_ID = '22222222-2222-4222-8222-222222222222'
            VALIDATE_PERSISTENT_SUBSCRIPTION_ID = '33333333-3333-4333-8333-333333333333'
            VALIDATE_MANAGEMENT_GROUP_ID = 'customer-root'
            VALIDATE_SUBSCRIPTION_IDS = $pool
        } | ConvertTo-Json -Compress
        $env:AVM_CI_SECRETS = '{"VALIDATE_CLIENT_ID":"unused-client","VALIDATE_TENANT_ID":"unused-tenant","VALIDATE_MANAGEMENT_GROUP_ID":"unused-group","VALIDATE_SUBSCRIPTION_IDS":"invalid-unused-pool"}'
        InModuleScope Avm.Authoring {
            $ci = Get-AvmBicepWorkflowEnvironment -Enabled
            $ci.Variables['VALIDATE_CLIENT_ID'] | Should -BeExactly '11111111-1111-4111-8111-111111111111'
            $ci.Variables['VALIDATE_PERSISTENT_SUBSCRIPTION_ID'] | Should -BeExactly '33333333-3333-4333-8333-333333333333'
            $ci.TenantId | Should -BeExactly '22222222-2222-4222-8222-222222222222'
            $ci.ManagementGroupId | Should -BeExactly 'customer-root'
            (Select-AvmBicepWorkflowSubscription -PoolJson $ci.PoolJson).SubscriptionId |
                Should -BeExactly '44444444-4444-4444-8444-444444444444'
        }
    }

    It 'prefers a customer management-group variable alias to a canonical secret' {
        $env:AVM_CI_VARIABLES = '{"ARM_MGMTGROUP_ID":"customer-root"}'
        $env:AVM_CI_SECRETS = '{"VALIDATE_MANAGEMENT_GROUP_ID":"canonical-secret-group"}'
        InModuleScope Avm.Authoring {
            (Get-AvmBicepWorkflowEnvironment -Enabled).ManagementGroupId | Should -BeExactly 'customer-root'
        }
    }

    It 'matches management-group precedence at position <Position>' -ForEach @(
        @{ Position = 0 }
        @{ Position = 1 }
        @{ Position = 2 }
        @{ Position = 3 }
        @{ Position = 4 }
        @{ Position = 5 }
    ) {
        $variables = [ordered]@{ VALIDATE_MANAGEMENT_GROUP_ID = 'canonical-variable'; ARM_MGMTGROUP_ID = 'legacy-variable' }
        $secrets = [ordered]@{ VALIDATE_MANAGEMENT_GROUP_ID = 'canonical-secret'; ARM_MGMTGROUP_ID = 'legacy-secret' }
        $expected = @('canonical-variable', 'legacy-variable', 'canonical-secret',
            'legacy-secret', 'canonical-environment', 'legacy-environment')[$Position]
        if ($Position -gt 0) { $variables['VALIDATE_MANAGEMENT_GROUP_ID'] = '' }
        if ($Position -gt 1) { $variables['ARM_MGMTGROUP_ID'] = '' }
        if ($Position -gt 2) { $secrets['VALIDATE_MANAGEMENT_GROUP_ID'] = '' }
        if ($Position -gt 3) { $secrets['ARM_MGMTGROUP_ID'] = '' }
        $env:AVM_CI_VARIABLES = ConvertTo-Json -InputObject $variables -Compress
        $env:AVM_CI_SECRETS = ConvertTo-Json -InputObject $secrets -Compress
        $env:VALIDATE_MANAGEMENT_GROUP_ID = if ($Position -gt 4) { '' } else { 'canonical-environment' }
        $env:ARM_MGMTGROUP_ID = 'legacy-environment'
        InModuleScope Avm.Authoring -Parameters @{ Expected = $expected } {
            param($Expected)
            (Get-AvmBicepWorkflowEnvironment -Enabled).ManagementGroupId | Should -BeExactly $Expected
        }
    }

    It 'rejects a malformed preferred management-group variable alias without using a secret' {
        $env:AVM_CI_VARIABLES = '{"ARM_MGMTGROUP_ID":42}'
        $env:AVM_CI_SECRETS = '{"VALIDATE_MANAGEMENT_GROUP_ID":"unused-secret-group"}'
        InModuleScope Avm.Authoring {
            { Get-AvmBicepWorkflowEnvironment -Enabled } | Should -Throw 'ARM_MGMTGROUP_ID must be a string.'
        }
    }

    It 'retains a malformed configured canonical pool instead of falling back to a legacy pool' {
        $env:AVM_CI_VARIABLES = '{"VALIDATE_SUBSCRIPTION_IDS":" ","TEST_SUBSCRIPTION_IDS":"legacy"}'
        InModuleScope Avm.Authoring {
            (Get-AvmBicepWorkflowEnvironment -Enabled).PoolJson | Should -BeExactly ' '
        }
    }

    It 'does not change the legacy vault selector while resolving validation fields' {
        $env:AVM_CI_VARIABLES = '{"CI_KEY_VAULT_NAME":"variable-value"}'
        $env:AVM_CI_SECRETS = '{"CI_KEY_VAULT_NAME":"secret-value"}'
        $env:CI_KEY_VAULT_NAME = 'explicit-environment-vault'
        InModuleScope Avm.Authoring {
            (Get-AvmBicepWorkflowEnvironment -Enabled).KeyVaultName | Should -BeExactly 'explicit-environment-vault'
        }
    }

    It 'rejects malformed or non-object CI data without including its contents: <Field> <Kind>' -ForEach @(
        @{ Field = 'AVM_CI_VARIABLES'; Kind = 'invalid'; Json = 'sensitive-canary' }
        @{ Field = 'AVM_CI_SECRETS'; Kind = 'invalid'; Json = 'sensitive-canary' }
        @{ Field = 'AVM_CI_SECRETS'; Kind = 'array'; Json = '["sensitive-canary"]' }
        @{ Field = 'AVM_CI_SECRETS'; Kind = 'string'; Json = '"sensitive-canary"' }
        @{ Field = 'AVM_CI_SECRETS'; Kind = 'null'; Json = 'null' }
    ) {
        [Environment]::SetEnvironmentVariable($Field, $Json, 'Process')
        InModuleScope Avm.Authoring -Parameters @{ Field = $Field } {
            param($Field)
            $failure = $null
            try { Get-AvmBicepWorkflowEnvironment -Enabled } catch { $failure = $_ }
            $failure | Should -Not -BeNullOrEmpty
            $failure.Exception.Message | Should -BeExactly "$Field must contain a JSON object."
            $failure.Exception.Message | Should -Not -Match 'sensitive-canary'
        }
    }
}

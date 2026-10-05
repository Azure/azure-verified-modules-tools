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
            'TEST_SUBSCRIPTION_IDS', 'VALIDATE_SUBSCRIPTION_ID', 'VALIDATE_TENANT_ID', 'CI_KEY_VAULT_NAME',
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

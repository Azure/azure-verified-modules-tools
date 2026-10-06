#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Bicep e2e settings' {
    It 'ships the ownership tag, run ID pattern and registry exemptions' {
        $settings = Get-Content -LiteralPath (Join-Path $script:moduleRoot 'Resources' 'bicep' 'settings.json') -Raw |
            ConvertFrom-Json -AsHashtable

        $settings['e2e']['ownershipTag'] | Should -BeExactly 'avm-e2e-run-id'
        $settings['e2e']['runIdPattern'] | Should -BeExactly '^[0-9a-f]{32}\z'
        $settings['conventionExemptions']['majorVersionAllowedModules'] | Should -Be @('avm/res/network/nat-gateway')
        $settings['conventionExemptions']['defaultsTestOptionalModules'] | Should -Be @('avm/res/aad/domain-service')
        $settings['conventionExemptions']['e2eIgnoreAllowedModules'] | Should -Contain 'avm/res/cache/redis'
        $settings['conventionExemptions']['e2eIgnoreAllowedModules'].Count | Should -Be 8
    }
}

Describe 'Test-AvmBicepRunId' {
    It 'returns <Expected> for <Label>' -ForEach @(
        @{ Label = 'a lowercase 32-hex string'; Value = '0123456789abcdef0123456789abcdef'; Expected = $true }
        @{ Label = 'uppercase hex'; Value = '0123456789ABCDEF0123456789ABCDEF'; Expected = $false }
        @{ Label = 'a short string'; Value = '0123'; Expected = $false }
        @{ Label = 'a trailing newline'; Value = "0123456789abcdef0123456789abcdef`n"; Expected = $false }
        @{ Label = 'a one-item array'; Value = @(, '0123456789abcdef0123456789abcdef'); Expected = $false }
        @{ Label = 'null'; Value = $null; Expected = $false }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Value = $Value; Expected = $Expected } {
            param($Value, $Expected)
            Test-AvmBicepRunId -RunId $Value | Should -Be $Expected
        }
    }
}

Describe 'Get-AvmBicepRunOwnership' {
    It 'classifies <Label> as <State>' -ForEach @(
        @{ Label = 'no tags'; Tags = $null; State = 'None'; Value = $null }
        @{ Label = 'unrelated tags'; Tags = @{ owner = 'x' }; State = 'None'; Value = $null }
        @{ Label = 'a non-dictionary'; Tags = 'avm-e2e-run-id'; State = 'None'; Value = $null }
        @{ Label = 'the exact run tag'; Tags = @{ 'avm-e2e-run-id' = 'run' }; State = 'Owned'; Value = 'run' }
        @{ Label = 'another run'; Tags = @{ 'avm-e2e-run-id' = 'other' }; State = 'Foreign'; Value = 'other' }
        @{ Label = 'a nonstring value'; Tags = @{ 'avm-e2e-run-id' = 1 }; State = 'Foreign'; Value = 1 }
        @{ Label = 'a case-variant key'; Tags = @{ 'AVM-E2E-RUN-ID' = 'run' }; State = 'Ambiguous'; Value = 'run' }
    ) {
        $result = InModuleScope Avm.Authoring -Parameters @{ Tags = $Tags } {
            param($Tags)
            Get-AvmBicepRunOwnership -Tags $Tags -RunId 'run'
        }
        $result.State | Should -BeExactly $State
        $result.Value | Should -Be $Value
    }

    It 'treats duplicate case-variant keys as ambiguous with no single value' {
        $tags = '{"avm-e2e-run-id":"run","Avm-E2e-Run-Id":"run"}' | ConvertFrom-Json -AsHashtable
        InModuleScope Avm.Authoring -Parameters @{ Tags = $tags } {
            param($Tags)
            $result = Get-AvmBicepRunOwnership -Tags $Tags -RunId 'run'
            $result.State | Should -BeExactly 'Ambiguous'
            $result.Value | Should -BeNullOrEmpty
        }
    }
}
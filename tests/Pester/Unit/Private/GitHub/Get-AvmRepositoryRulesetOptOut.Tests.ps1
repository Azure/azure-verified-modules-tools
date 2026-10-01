#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmRepositoryRulesetOptOut' {
    It 'returns <Expected> for the global ruleset opt-out property' -TestCases @(
        @{ Value = 'true'; Expected = 'true' }
        @{ Value = 'false'; Expected = 'false' }
        @{ Value = $null; Expected = $null }
    ) {
        param($Value, $Expected)
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ Value = $Value } {
            param($Value)
            Mock Invoke-AvmGitHubApi -MockWith ({
                    @{ property_name = 'activeRepoStatus'; value = 'true' }
                    @{ property_name = 'rulesets-default-opt-in'; value = 'true' }
                    if ($null -ne $Value) { @{ property_name = 'global-rulesets-opt-out'; value = $Value } }
                }.GetNewClosure())
            Get-AvmRepositoryRulesetOptOut -Repository 'Azure/repo'
            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter { $Endpoint -eq 'repos/Azure/repo/properties/values' }
        }
        $result | Should -Be $Expected
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'duplicate properties'; Properties = @(
                @{ property_name = 'global-rulesets-opt-out'; value = 'true' }
                @{ property_name = 'global-rulesets-opt-out'; value = 'false' }
            ); Message = 'duplicate'
        }
        @{ Case = 'unexpected values'; Properties = @(@{ property_name = 'global-rulesets-opt-out'; value = 'yes' }); Message = 'invalid global-rulesets-opt-out value' }
        @{ Case = 'non-object entries'; Properties = @('global-rulesets-opt-out'); Message = 'invalid custom properties' }
    ) {
        param($Case, $Properties, $Message)
        $probe = InModuleScope 'Avm.Authoring' -Parameters @{ Properties = $Properties } {
            param($Properties)
            Mock Invoke-AvmGitHubApi -MockWith ({ $Properties }.GetNewClosure())
            try { Get-AvmRepositoryRulesetOptOut -Repository 'Azure/repo' } catch { $_.Exception }
        }
        $probe.GetType().Name | Should -Be 'InvalidDataException'
        $probe.Message | Should -Match $Message
    }
}

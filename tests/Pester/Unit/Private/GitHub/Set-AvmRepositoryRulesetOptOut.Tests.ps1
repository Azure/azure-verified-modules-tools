#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Set-AvmRepositoryRulesetOptOut' {
    It 'patches only the global ruleset opt-out and verifies <Value>' -TestCases @(
        @{ Value = 'true' }
        @{ Value = 'false' }
        @{ Value = $null }
    ) {
        param($Value)
        InModuleScope 'Avm.Authoring' -Parameters @{ Value = $Value } {
            param($Value)
            Mock Invoke-AvmGitHubApi {}
            Mock Get-AvmRepositoryRulesetOptOut -MockWith ({ $Value }.GetNewClosure())

            Set-AvmRepositoryRulesetOptOut -Repository 'Azure/repo' -Value $Value -Confirm:$false

            Should -Invoke Invoke-AvmGitHubApi -Exactly 1 -ParameterFilter {
                $Method -eq 'PATCH' -and $Endpoint -eq 'repos/Azure/repo/properties/values' -and
                @($Body.properties).Count -eq 1 -and
                $Body.properties[0].property_name -ceq 'global-rulesets-opt-out' -and
                $Body.properties[0].value -ceq $Value
            }
            Should -Invoke Get-AvmRepositoryRulesetOptOut -Exactly 1
        }
    }

    It 'fails when GitHub does not report the requested value' {
        $probe = InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmGitHubApi {}
            Mock Get-AvmRepositoryRulesetOptOut { 'false' }
            try { Set-AvmRepositoryRulesetOptOut -Repository 'Azure/repo' -Value 'true' -Confirm:$false } catch { $_.Exception }
        }
        $probe.GetType().Name | Should -Be 'InvalidOperationException'
        $probe.Message | Should -Match 'Could not verify global-rulesets-opt-out=true for Azure/repo'
    }

    It 'rejects values other than true, false, or null before calling GitHub' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmGitHubApi {}
            { Set-AvmRepositoryRulesetOptOut -Repository 'Azure/repo' -Value $true -Confirm:$false } |
                Should -Throw '*must be the string true, false, or null*'
            Should -Invoke Invoke-AvmGitHubApi -Exactly 0
        }
    }

    It 'changes nothing under WhatIf' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmGitHubApi {}
            Set-AvmRepositoryRulesetOptOut -Repository 'Azure/repo' -Value 'true' -WhatIf
            Should -Invoke Invoke-AvmGitHubApi -Exactly 0
        }
    }
}

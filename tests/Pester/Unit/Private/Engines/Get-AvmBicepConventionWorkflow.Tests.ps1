#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepConventionWorkflow' {
    It 'resolves the pinned YAML parser through shared prerequisites before reading a workflow' {
        InModuleScope 'Avm.Authoring' {
            Mock Import-AvmPowerShellModule { throw [AvmToolException]::new('Run: avm tool install powershell-yaml') }

            { Get-AvmBicepConventionWorkflow -Path 'unused.yml' -ModuleRoot $TestDrive } |
                Should -Throw '*avm tool install powershell-yaml*'
            Should -Invoke Import-AvmPowerShellModule -Exactly 1 -ParameterFilter {
                $Name -ceq 'powershell-yaml' -and $ModuleRoot -eq $TestDrive
            }
        }
    }

    It 'does not use an older parser in place of the required version' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Module {
                [pscustomobject]@{ Name = 'powershell-yaml'; Version = [version]'0.4.2' }
            } -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' }
            Mock Get-AvmToolCacheEntry { [pscustomobject]@{ Cached = $false; Path = 'unused.psd1' } }
            Mock Install-AvmToolFromPins { throw [AvmToolException]::new('Fixture download unavailable.') }

            { Get-AvmBicepConventionWorkflow -Path 'unused.yml' } |
                Should -Throw '*powershell-yaml 0.4.12*'
            Should -Invoke Install-AvmToolFromPins -Exactly 1 -ParameterFilter {
                $Tool.name -ceq 'powershell-yaml' -and $Tool.version -ceq '0.4.12'
            }
        }
    }
}

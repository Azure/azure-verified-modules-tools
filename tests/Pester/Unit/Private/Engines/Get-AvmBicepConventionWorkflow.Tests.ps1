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
    It 'requires the pinned YAML parser before reading a workflow' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Module { @() } -ParameterFilter {
                $ListAvailable -and $Name -eq 'powershell-yaml'
            }
            Mock Import-Module { throw 'Parser must not be imported.' } -ParameterFilter {
                $Name -eq 'powershell-yaml'
            }

            { Get-AvmBicepConventionWorkflow -Path 'unused.yml' } |
                Should -Throw '*Install-PSResource -Name powershell-yaml -Version 0.4.12*'
            Should -Invoke Import-Module -Exactly 0 -ParameterFilter {
                $Name -eq 'powershell-yaml'
            }
        }
    }

    It 'does not use an older parser in place of the required version' {
        InModuleScope 'Avm.Authoring' {
            Mock Get-Module {
                [pscustomobject]@{ Name = 'powershell-yaml'; Version = [version]'0.4.2' }
            } -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' }

            { Get-AvmBicepConventionWorkflow -Path 'unused.yml' } |
                Should -Throw '*powershell-yaml 0.4.12*'
        }
    }
}

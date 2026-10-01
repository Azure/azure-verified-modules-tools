#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..')).ProviderPath
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepCompiledJson offline behavior' -Tag 'Unit' {
    It 'builds with --no-restore only when AVM_OFFLINE=1' {
        InModuleScope 'Avm.Authoring' {
            Mock Invoke-AvmProcess {
                [pscustomobject]@{
                    ExitCode = 0
                    StdOut = '{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","contentVersion":"1.0.0.0","resources":[]}'
                    StdErr = ''
                }
            }
            $previous = $env:AVM_OFFLINE
            try {
                $env:AVM_OFFLINE = '1'
                $offline = Get-AvmBicepCompiledJson -SourcePath 'main.bicep' -ToolPath 'mock-bicep'
                $offline | Should -Match 'deploymentTemplate.json'
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList -contains '--no-restore'
                }

                Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
                $online = Get-AvmBicepCompiledJson -SourcePath 'main.bicep' -ToolPath 'mock-bicep'
                $online | Should -BeExactly $offline
                Should -Invoke Invoke-AvmProcess -Exactly 1 -ParameterFilter {
                    $ArgumentList -notcontains '--no-restore'
                }
            }
            finally {
                if ($null -eq $previous) {
                    Remove-Item Env:AVM_OFFLINE -ErrorAction SilentlyContinue
                }
                else {
                    $env:AVM_OFFLINE = $previous
                }
            }
        }
    }
}

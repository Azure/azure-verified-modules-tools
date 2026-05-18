#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-AvmBicepDocs' {
    It 'rejects a non-bicep context' {
        $tfCtx = [pscustomobject][ordered]@{
            Kind = 'terraform-module-repo'; Root = $TestDrive; Ecosystem = 'terraform'; Source = 'path-heuristic'
        }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $tfCtx } {
                param($C)
                Invoke-AvmBicepDocs -Context $C
            }
        } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'throws AvmConfigurationException because the ARM-JSON walker has not landed' {
        $bicepCtx = [pscustomobject][ordered]@{
            Kind = 'bicep-module'; Root = $TestDrive; Ecosystem = 'bicep'; Source = 'path-heuristic'
        }
        $err = $null
        try {
            InModuleScope 'Avm.Authoring' -Parameters @{ C = $bicepCtx } {
                param($C)
                Invoke-AvmBicepDocs -Context $C
            }
        }
        catch {
            $err = $_.Exception
        }
        $err                | Should -Not -BeNullOrEmpty
        $err.GetType().Name | Should -Be 'AvmConfigurationException'
        $err.Message        | Should -Match 'ARM-JSON walker'
    }
}

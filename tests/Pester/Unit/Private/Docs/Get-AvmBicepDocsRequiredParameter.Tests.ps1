#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Get-AvmBicepDocsRequiredParameter' {
    It 'uses compiled defaults and nullable references to identify required names' {
        $template = @{
            parameters = [ordered]@{
                name     = @{ type = 'string' }
                location = @{ type = 'string'; defaultValue = 'westus' }
                settings = @{ '$ref' = '#/definitions/optionalSettings' }
                tags     = @{ type = 'object'; nullable = $true }
            }
            definitions = @{
                optionalSettings = @{ type = 'object'; nullable = $true }
            }
        }
        $required = @(InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
                param($T)
                Get-AvmBicepDocsRequiredParameter -Template $T -SourcePath 'main.json'
            })
        $required | Should -Be @('name')
    }

    It 'rejects an unresolved compiled definition' {
        $template = @{ parameters = @{ settings = @{ '$ref' = '#/definitions/missing' } } }
        {
            InModuleScope 'Avm.Authoring' -Parameters @{ T = $template } {
                param($T)
                Get-AvmBicepDocsRequiredParameter -Template $T -SourcePath 'main.json'
            }
        } | Should -Throw "*missing definition 'missing'*main.json*"
    }
}

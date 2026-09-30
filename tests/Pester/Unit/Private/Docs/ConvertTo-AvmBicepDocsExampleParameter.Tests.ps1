#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring')
    Import-Module (Join-Path $script:moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-AvmBicepDocsExampleParameter' {
    It 'renders sorted nested values and groups required parameters in all three formats' {
        $parameters = @{
            tags = @{ value = @{ Role = 'Integration'; Environment = 'Test' } }
            name = @{ value = 'demo' }
            location = @{ value = '<location>' }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $parameters } {
            param($P)
            ConvertTo-AvmBicepDocsExampleParameter -Parameters $P -RequiredParameters @('name')
        }
        $result.BicepParameters | Should -BeExactly @'
    // Required parameters
    name: 'demo'
    // Non-required parameters
    location: '<location>'
    tags: {
      Environment: 'Test'
      Role: 'Integration'
    }
'@.ReplaceLineEndings("`n")
        $result.BicepParameterFile | Should -BeExactly @'
// Required parameters
param name = 'demo'
// Non-required parameters
param location = '<location>'
param tags = {
  Environment: 'Test'
  Role: 'Integration'
}
'@.ReplaceLineEndings("`n")
        $result.JsonParameters | Should -Match '(?m)^    // Required parameters$'
        $result.JsonParameters | Should -Match '(?m)^    // Non-required parameters$'
        $parsedJson = ($result.JsonParameters -replace '(?m)^    // .+\n', '') |
            ConvertFrom-Json -AsHashtable
        $parsedJson.parameters.name.value | Should -BeExactly 'demo'
        $parsedJson.parameters.tags.value.Environment | Should -BeExactly 'Test'
    }

    It 'keeps a single required parameter free of section comments' {
        $result = InModuleScope 'Avm.Authoring' {
            ConvertTo-AvmBicepDocsExampleParameter -Parameters @{
                name = @{ value = 'standalone' }
            } -RequiredParameters @('name')
        }
        $result.BicepParameters | Should -BeExactly "    name: 'standalone'"
        $result.JsonParameters | Should -Not -Match 'Required parameters'
    }

    It 'enumerates a parameter and nested property named keys' {
        $parameters = @{
            keys = @{ value = @(@{ keys = @('a'); name = 'demo' }) }
            name = @{ value = 'vault' }
        }
        $result = InModuleScope 'Avm.Authoring' -Parameters @{ P = $parameters } {
            param($P)
            ConvertTo-AvmBicepDocsExampleParameter -Parameters $P -RequiredParameters @('name')
        }
        $parsed = ($result.JsonParameters -replace '(?m)^    // .+\n', '') |
            ConvertFrom-Json -AsHashtable
        $parsed.parameters.keys.value[0].keys[0] | Should -BeExactly 'a'
        $parsed.parameters.name.value | Should -BeExactly 'vault'
    }
}

#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep workflow authored parameter names' -Tag Component {
    It 'preserves keys and count tokens from a dictionary and from a file' {
        $file = Join-Path $TestDrive 'tokens.json'
        [IO.File]::WriteAllText($file, '{"keys":"literal-key","count":"0"}')
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive } {
            param($Root)
            $arguments = @{ Root = $Root; SubscriptionId = '00000000-0000-0000-0000-000000000001' }
            $direct = Get-AvmBicepTestTokenMap @arguments -Tokens @{ keys = 'literal-key'; count = '0' }
            $fromFile = Get-AvmBicepTestTokenMap @arguments -TokenFile 'tokens.json'
            foreach ($actual in @($direct, $fromFile)) {
                $actual.psbase.Count | Should -Be 3
                $actual['keys'] | Should -Be 'literal-key'
                $actual['count'] | Should -Be '0'
            }
            { Get-AvmBicepTestTokenMap @arguments -TokenFile 'tokens.json' -Tokens @{ count = '0' } } |
                Should -Throw -ExpectedMessage '*not both*'
        }
    }

    It 'retains keys and count parameters even when count is zero' {
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive } {
            param($Root)
            $tokens = Get-AvmBicepTestTokenMap -Root $Root `
                -SubscriptionId '00000000-0000-0000-0000-000000000001'
            $destination = Join-Path $Root 'parameters.json'
            $actual = New-AvmBicepTestParameterFile -Root $Root -DestinationPath $destination `
                -Tokens $tokens -Parameters @{ keys = @('first', 'second'); count = 0 }
            $actual | Should -Be $destination
            $values = ([IO.File]::ReadAllText($actual) | ConvertFrom-Json -AsHashtable)['parameters']
            $values.psbase.Count | Should -Be 2
            $values['keys']['value'] | Should -Be @('first', 'second')
            $values['count']['value'] | Should -Be 0
            { New-AvmBicepTestParameterFile -Root $Root -DestinationPath $destination `
                    -Tokens $tokens -ParameterFile 'parameters.json' -Parameters @{ count = 0 } } |
                Should -Throw -ExpectedMessage '*not both*'
        }
    }

    It 'validates a keys parameter from an authored file rather than iterating its value' {
        $source = Join-Path $TestDrive 'authored-parameters.json'
        [IO.File]::WriteAllText($source, '{"parameters":{"keys":{"value":["first"]},"count":{"value":0}}}')
        InModuleScope Avm.Authoring -Parameters @{ Root = $TestDrive; Source = $source } {
            param($Root, $Source)
            $tokens = Get-AvmBicepTestTokenMap -Root $Root `
                -SubscriptionId '00000000-0000-0000-0000-000000000001'
            $actual = New-AvmBicepTestParameterFile -Root $Root -DestinationPath (Join-Path $Root 'copied.json') `
                -Tokens $tokens -ParameterFile $Source
            $values = ([IO.File]::ReadAllText($actual) | ConvertFrom-Json -AsHashtable)['parameters']
            $values['keys']['value'][0] | Should -Be 'first'
            $values['count']['value'] | Should -Be 0
        }
    }
}

#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Resolve-AvmBicepParameterToken' {
    It 'retains the underlying scalar type of decorated JSON <Json>' -ForEach @(
        @{ Json = '0' }, @{ Json = '7' }, @{ Json = 'false' }, @{ Json = 'true' }, @{ Json = '1.5' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Json = $Json } {
            param($Json)
            $value = ConvertFrom-Json -InputObject $Json -NoEnumerate -AsHashtable
            $map = [Collections.Generic.Dictionary[string, string]]::new()
            $result = Resolve-AvmBicepParameterToken -Value @{ input = $value } -Tokens $map
            $result['input'].GetType() | Should -Be $value.GetType()
            $result['input'] | Should -Be $value
        }
    }

    It 'preserves null, custom objects, empty and nested arrays, and secure strings' {
        InModuleScope Avm.Authoring {
            $map = [Collections.Generic.Dictionary[string, string]]::new()
            $map.Add('example', 'resolved')
            $secret = ConvertTo-SecureString 'fixture-only' -AsPlainText -Force
            $value = [pscustomobject]@{
                nil = $null; keys = @(); count = 0; nested = @(, @('#_example_#')); secure = $secret
            }
            $result = Resolve-AvmBicepParameterToken -Value $value -Tokens $map
            $result.GetType().FullName | Should -Be 'System.Management.Automation.PSCustomObject'
            $result.nil | Should -BeNullOrEmpty
            ($result.keys -is [array]) | Should -BeTrue
            $result.keys.Count | Should -Be 0
            $result.count | Should -Be 0
            ($result.nested[0] -is [array]) | Should -BeTrue
            $result.nested[0][0] | Should -BeExactly 'resolved'
            [object]::ReferenceEquals($result.secure, $secret) | Should -BeTrue
            $value.nested[0][0] | Should -BeExactly '#_example_#'
        }
    }
}

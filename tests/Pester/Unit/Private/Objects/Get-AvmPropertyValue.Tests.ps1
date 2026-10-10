#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' '..' 'src' 'Avm.Authoring'
    & (Join-Path $PSScriptRoot '..' '..' '..' 'Import-AvmTestModule.ps1') `
        -SourceManifest (Join-Path $moduleRoot 'Avm.Authoring.psd1')
}
AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Property value shape preservation' {
    It 'preserves empty and singleton arrays only when requested: <ObjectKind>' -ForEach @(
        @{ ObjectKind = 'dictionary' }, @{ ObjectKind = 'PSObject' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ ObjectKind = $ObjectKind } {
            param($ObjectKind)
            foreach ($value in @(@(), @(200), @(200, 404))) {
                $inputValue = @{ field = $value }
                if ($ObjectKind -eq 'PSObject') { $inputValue = [pscustomobject]$inputValue }
                $actual = Get-AvmPropertyValue -InputObject $inputValue -Name field -NoEnumerate
                [object]::ReferenceEquals($actual, $value) | Should -BeTrue
                @(Get-AvmPropertyValue -InputObject $inputValue -Name field).Count | Should -Be $value.Count
            }
        }
    }

    It 'keeps scalar, null, missing and dictionary values unchanged' {
        InModuleScope Avm.Authoring {
            $inputValue = @{ scalar = 200; empty = $null; body = @{ code = 'Failed' } }
            Get-AvmPropertyValue -InputObject $inputValue -Name scalar -NoEnumerate | Should -Be 200
            Get-AvmPropertyValue -InputObject $inputValue -Name empty -NoEnumerate | Should -BeNullOrEmpty
            Get-AvmPropertyValue -InputObject $inputValue -Name missing -NoEnumerate | Should -BeNullOrEmpty
            Get-AvmPropertyValue -InputObject $null -Name missing -NoEnumerate | Should -BeNullOrEmpty
            $body = Get-AvmPropertyValue -InputObject $inputValue -Name body -NoEnumerate
            [object]::ReferenceEquals($body, $inputValue.body) | Should -BeTrue
        }
    }
}

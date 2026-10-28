#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll { Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue }

Describe 'Get-AvmBicepAzureDependency' {
    It 'exposes every preflight dependency and its minimum version without installation or imports' {
        InModuleScope Avm.Authoring {
            $requirements = @(Get-AvmBicepAzureRequirement)
            Mock Test-AvmModuleVersion {}
            Mock Import-Module { throw 'Inventory must not import modules.' }
            Mock Install-PSResource { throw 'Inventory must not install modules.' }
            $inventory = @(Get-AvmBicepAzureDependency)
            $inventory.Count | Should -Be $requirements.Count
            foreach ($requirement in $requirements) {
                $entry = @($inventory | Where-Object Name -CEQ $requirement.Name)
                $entry.Count | Should -Be 1
                $entry[0].MinimumVersion | Should -Be ([version]$requirement.MinimumVersion)
            }
            @($inventory | Where-Object Name -CEQ 'Az.Subscription')[0].MinimumVersion | Should -Be ([version]'0.12.0')
            Should -Invoke Import-Module -Exactly 0
            Should -Invoke Install-PSResource -Exactly 0
            Should -Invoke Test-AvmModuleVersion -Exactly 1
        }
    }
}

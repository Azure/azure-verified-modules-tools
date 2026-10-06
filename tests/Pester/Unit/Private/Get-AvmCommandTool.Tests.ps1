#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $moduleRoot = Join-Path $PSScriptRoot '..' '..' '..' '..' 'src' 'Avm.Authoring'
    Import-Module (Join-Path $moduleRoot 'Avm.Authoring.psd1') -Force
}

AfterAll { Remove-Module Avm.Authoring -Force }

Describe 'Get-AvmCommandTool complete prerequisites' {
    It 'selects only the dependencies needed by <Command> <Ecosystem>' -ForEach @(
        @{ Command = 'pre-commit'; Ecosystem = 'terraform'; Names = @('mapotf', 'terraform', 'terraform-docs', 'Pester') }
        @{ Command = 'pr-check'; Ecosystem = 'terraform'; Names = @('conftest', 'mapotf', 'terraform', 'terraform-docs', 'tflint', 'Pester') }
        @{ Command = 'pre-commit'; Ecosystem = 'bicep'; Names = @('bicep', 'Pester') }
        @{ Command = 'pr-check'; Ecosystem = 'bicep'; Names = @('bicep', 'Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure') }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Command = $Command; Ecosystem = $Ecosystem; Names = $Names } {
            param($Command, $Ecosystem, $Names)
            @(Get-AvmCommandTool -Command $Command -Ecosystem $Ecosystem) | Should -Be $Names
            Mock Resolve-AvmTool {
                param($Name)
                [pscustomobject]@{
                    Name = $Name; Version = '1.0.0'; Source = 'cache'; Path = 'resolved'
                    Kind = if ($Name -in @('Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure')) { 'powershell-module' } else { 'binary' }
                }
            }
            Mock Import-AvmPowerShellModule
            $result = @(Resolve-AvmCommandTool -Command $Command -Ecosystem $Ecosystem -ModuleRoot 'authoritative-root')
            $result.Name | Should -Be $Names
            Should -Invoke Resolve-AvmTool -Exactly $Names.Count -ParameterFilter { $ModuleRoot -ceq 'authoritative-root' }
            $moduleCount = @($Names | Where-Object { $_ -in @('Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure') }).Count
            Should -Invoke Import-AvmPowerShellModule -Exactly $moduleCount -ParameterFilter { $ModuleRoot -ceq 'authoritative-root' }
        }
    }
}

Describe 'Runtime prerequisite ordering' {
    It 'stops <Command> before metadata if a PowerShell prerequisite cannot load' -ForEach @(
        @{ Command = 'Invoke-AvmPreCommit' }
        @{ Command = 'Invoke-AvmPrCheck' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Command = $Command } {
            param($Command)
            Mock Test-AvmModuleVersion
            Mock Get-AvmModuleContextInternal { [pscustomobject]@{ Root = 'root'; Ecosystem = 'terraform'; Kind = 'terraform-module-repo' } }
            Mock Assert-AvmGitWorkingTreeClean
            Mock Resolve-AvmTool {
                param($Name)
                [pscustomobject]@{
                    Name = $Name; Version = '1.0.0'; Source = 'cache'; Path = 'resolved'
                    Kind = if ($Name -eq 'Pester') { 'powershell-module' } else { 'binary' }
                }
            }
            Mock Import-AvmPowerShellModule { throw [AvmToolException]::new('Pester failed to import.', 'AVM1013') }
            Mock Test-AvmMetadataModules
            Mock Invoke-AvmSync
            Mock Invoke-AvmFormat
            { & $Command -Path root } | Should -Throw '*Pester failed to import*'
            Should -Invoke Import-AvmPowerShellModule -Exactly 1 -ParameterFilter { $Name -ceq 'Pester' -and $ModuleRoot -ceq 'root' }
            Should -Invoke Test-AvmMetadataModules -Exactly 0
            Should -Invoke Invoke-AvmSync -Exactly 0
            Should -Invoke Invoke-AvmFormat -Exactly 0
        }
    }

    It 'keeps upgrade enforcement ahead of all <Command> prerequisites' -ForEach @(
        @{ Command = 'Invoke-AvmPreCommit' }
        @{ Command = 'Invoke-AvmPrCheck' }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Command = $Command } {
            param($Command)
            Mock Test-AvmModuleVersion {
                throw [AvmModuleVersionException]::new([version]'0.0.0', [version]'0.20.0', 'Update-PSResource and Import-Module are required.')
            }
            Mock Get-AvmModuleContextInternal
            Mock Resolve-AvmCommandTool
            Mock Test-AvmMetadataModules
            $failure = $null
            try { & $Command -Path root }
            catch { $failure = $_.Exception }
            $failure.Code | Should -Be 'AVM1050'
            $failure.ExitCode | Should -Be 10
            Should -Invoke Test-AvmModuleVersion -Exactly 1 -ParameterFilter { -not $SkipModuleVersionCheck }
            Should -Invoke Get-AvmModuleContextInternal -Exactly 0
            Should -Invoke Resolve-AvmCommandTool -Exactly 0
            Should -Invoke Test-AvmMetadataModules -Exactly 0
        }
    }
}

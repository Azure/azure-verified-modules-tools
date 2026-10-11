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

Describe 'Get-AvmCommandTool excluded steps' {
    It 'resolves only <Ecosystem> prerequisites for the remaining <Step> step' -ForEach @(
        @{ Ecosystem = 'terraform'; Step = 'metadata'; Names = @('Pester') }
        @{ Ecosystem = 'terraform'; Step = 'sync'; Names = @() }
        @{ Ecosystem = 'terraform'; Step = 'format'; Names = @('terraform') }
        @{ Ecosystem = 'terraform'; Step = 'transform'; Names = @('mapotf', 'terraform') }
        @{ Ecosystem = 'terraform'; Step = 'lint'; Names = @('terraform', 'tflint') }
        @{ Ecosystem = 'terraform'; Step = 'check policy'; Names = @('conftest', 'terraform') }
        @{ Ecosystem = 'terraform'; Step = 'check convention'; Names = @() }
        @{ Ecosystem = 'terraform'; Step = 'validate'; Names = @('terraform') }
        @{ Ecosystem = 'terraform'; Step = 'docs'; Names = @('terraform-docs') }
        @{ Ecosystem = 'bicep'; Step = 'metadata'; Names = @('Pester') }
        @{ Ecosystem = 'bicep'; Step = 'sync'; Names = @() }
        @{ Ecosystem = 'bicep'; Step = 'format'; Names = @('bicep') }
        @{ Ecosystem = 'bicep'; Step = 'transform'; Names = @('bicep') }
        @{ Ecosystem = 'bicep'; Step = 'lint'; Names = @('bicep') }
        @{ Ecosystem = 'bicep'; Step = 'check policy'; Names = @('bicep', 'PSRule', 'PSRule.Rules.Azure') }
        @{ Ecosystem = 'bicep'; Step = 'check convention'; Names = @('bicep', 'Pester', 'powershell-yaml') }
        @{ Ecosystem = 'bicep'; Step = 'validate'; Names = @('bicep') }
        @{ Ecosystem = 'bicep'; Step = 'docs'; Names = @('bicep', 'Pester') }
        @{ Ecosystem = 'terraform'; Step = 'none'; Names = @() }
        @{ Ecosystem = 'bicep'; Step = 'none'; Names = @() }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Ecosystem = $Ecosystem; Step = $Step; Names = $Names } {
            param($Ecosystem, $Step, $Names)
            $exclusions = @('metadata', 'sync', 'format', 'transform', 'lint', 'check policy', 'check convention', 'validate', 'docs') |
                Where-Object { $_ -ne $Step }
            Mock Resolve-AvmTool {
                param($Name)
                [pscustomobject]@{
                    Name = $Name; Version = '1.0.0'; Source = 'cache'; Path = 'resolved'
                    Kind = if ($Name -in @('Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure')) { 'powershell-module' } else { 'binary' }
                }
            }
            Mock Import-AvmPowerShellModule
            $result = @(Resolve-AvmCommandTool -Command pr-check -Ecosystem $Ecosystem -ExcludeSteps $exclusions -ModuleRoot root -AllowPathFallback)

            $result | Should -HaveCount $Names.Count
            if ($Names.Count -gt 0) {
                $result.Name | Should -Be $Names
            }
            Should -Invoke Resolve-AvmTool -Exactly $Names.Count -ParameterFilter { $ModuleRoot -eq 'root' -and $AllowPathFallback }
            $moduleCount = @($Names | Where-Object { $_ -in @('Pester', 'powershell-yaml', 'PSRule', 'PSRule.Rules.Azure') }).Count
            Should -Invoke Import-AvmPowerShellModule -Exactly $moduleCount -ParameterFilter { $ModuleRoot -eq 'root' }
        }
    }

    It 'retains shared tools for <Ecosystem> after excluding <Exclusions>' -ForEach @(
        @{ Ecosystem = 'terraform'; Exclusions = @('check policy'); Names = @('mapotf', 'terraform', 'terraform-docs', 'tflint', 'Pester') }
        @{ Ecosystem = 'terraform'; Exclusions = @('CHECK POLICY', 'Lint', 'lint', 'docs'); Names = @('mapotf', 'terraform', 'Pester') }
        @{ Ecosystem = 'bicep'; Exclusions = @('metadata', 'check policy'); Names = @('bicep', 'Pester', 'powershell-yaml') }
        @{ Ecosystem = 'bicep'; Exclusions = @('check convention'); Names = @('bicep', 'Pester', 'PSRule', 'PSRule.Rules.Azure') }
    ) {
        InModuleScope Avm.Authoring -Parameters @{ Ecosystem = $Ecosystem; Exclusions = $Exclusions; Names = $Names } {
            param($Ecosystem, $Exclusions, $Names)
            @(Get-AvmCommandTool -Command pr-check -Ecosystem $Ecosystem -ExcludeSteps $Exclusions) | Should -Be $Names
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

#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Qualification: packaged Terraform acceptance fixture stability' -Tag Qualification {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
        $package = Join-Path $script:repoRoot 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module -Name $package -Force -ErrorAction Stop
        (Get-Module Avm.Authoring).ModuleBase | Should -BeExactly (Split-Path $package -Parent)
        . (Join-Path $PSScriptRoot '..' '..' 'Helpers' 'TerraformAcceptance.ps1')
    }

    AfterAll { Remove-Module Avm.Authoring -Force }

    It 'preserves reviewed <Scenario> bytes and all four mocked runs without a cloud policy plan' -ForEach @(
        @{ Scenario = 'canonical'; Legacy = $false }
        @{ Scenario = 'legacy migration'; Legacy = $true }
    ) {
        $name = 'terraform-azure-avm-res-mock'
        $parameters = @{
            Source = Join-Path $script:repoRoot 'tests' 'fixtures' 'modules' $name
            Name = $name
            InitializeLock = -not $Legacy
        }
        $migration = Join-Path $script:repoRoot 'tests' 'fixtures' 'migrations' 'utility'
        if ($Legacy) { $parameters.Overlay = Join-Path $migration 'input' }
        $context = New-TerraformAcceptanceContext @parameters
        try {
            $expected = $context.Authored.Clone()
            if ($Legacy) {
                $golden = Get-TerraformAcceptanceFiles -Root (Join-Path $migration 'expected')
                $golden.Count | Should -BeGreaterThan 0
                foreach ($path in $golden.Keys) { $expected[$path] = $golden[$path] }
            }
            $null = Invoke-TerraformAcceptancePreCommit -Context $context
            Assert-TerraformAcceptanceFiles -Context $context -Expected $expected
            $first = Get-TerraformAcceptanceFiles -Root $context.Root -Authored $expected `
                -ConfigurationDirectories $context.ConfigurationDirectories

            $null = Invoke-TerraformAcceptancePreCommit -Context $context
            Assert-TerraformAcceptanceFiles -Context $context -Expected $first
            $null = Invoke-TerraformAcceptanceUnit -Context $context -Runs 4
            Assert-TerraformAcceptanceFiles -Context $context -Expected $first
        }
        finally { Remove-TerraformAcceptanceContext -Context $context }
    }
}

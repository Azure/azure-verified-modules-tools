#Requires -Module @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Acceptance: packaged Terraform commands' -Tag Integration {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $package = Join-Path $script:repoRoot 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module -Name $package -Force -ErrorAction Stop
        (Get-Module Avm.Authoring).ModuleBase | Should -BeExactly (Split-Path $package -Parent)
        . (Join-Path $PSScriptRoot '..' 'Helpers' 'TerraformAcceptance.ps1')
    }

    AfterAll { Remove-Module Avm.Authoring -Force }

    Context '<Name>' -ForEach (@(
            @{ Name = 'terraform-azure-avm-res-mock'; UnitRuns = 4 }
            @{ Name = 'terraform-azurerm-avm-res-mock'; UnitRuns = 2 }
        ) | Where-Object { -not $env:AVM_INTEGRATION_FIXTURE -or $_.Name -ceq $env:AVM_INTEGRATION_FIXTURE }) {
        It 'keeps canonical bytes unchanged on both public pre-commit runs and full pr-check' {
            $source = Join-Path $script:repoRoot 'tests' 'fixtures' 'modules' $Name
            $context = New-TerraformAcceptanceContext -Source $source -Name $Name -InitializeLock
            try {
                $context.Authored.ContainsKey('.terraform.lock.hcl') | Should -BeTrue
                (Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @(
                        'ls-files', '--error-unmatch', '.terraform.lock.hcl'
                    )).StdOut.Trim() | Should -BeExactly '.terraform.lock.hcl'
                $null = Invoke-TerraformAcceptancePreCommit -Context $context
                Assert-TerraformAcceptanceFiles -Context $context -Expected $context.Authored
                $first = Get-TerraformAcceptanceFiles -Root $context.Root -Authored $context.Authored `
                    -ConfigurationDirectories $context.ConfigurationDirectories
                $null = Invoke-TerraformAcceptancePreCommit -Context $context
                Assert-TerraformAcceptanceFiles -Context $context -Expected $first

                $null = Invoke-TerraformAcceptanceUnit -Context $context -Runs $UnitRuns
                Assert-TerraformAcceptanceFiles -Context $context -Expected $first

                $null = Invoke-TerraformAcceptancePrCheck -Context $context
                Assert-TerraformAcceptanceFiles -Context $context -Expected $first
                (Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @('status', '--porcelain')).StdOut |
                    Should -BeNullOrEmpty
            }
            finally { Remove-TerraformAcceptanceContext -Context $context }
        }
    }
}

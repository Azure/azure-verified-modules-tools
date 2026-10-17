#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

Describe 'Acceptance: packaged utility migration' -Tag Integration -ForEach (@(
        @{ Fixture = 'terraform-azure-avm-res-mock' }
    ) | Where-Object { -not $env:AVM_INTEGRATION_FIXTURE -or $_.Fixture -ceq $env:AVM_INTEGRATION_FIXTURE }) {
    BeforeAll {
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
        $package = Join-Path $script:repoRoot 'out' 'Avm.Authoring' 'Avm.Authoring.psd1'
        Import-Module -Name $package -Force -ErrorAction Stop
        (Get-Module Avm.Authoring).ModuleBase | Should -BeExactly (Split-Path $package -Parent)
        . (Join-Path $PSScriptRoot '..' 'Helpers' 'TerraformAcceptance.ps1')
    }

    AfterAll { Remove-Module Avm.Authoring -Force }

    It 'produces reviewed legacy upgrades once, then keeps all bytes on the second public pre-commit and pr-check' {
        $migration = Join-Path $script:repoRoot 'tests' 'fixtures' 'migrations' 'utility'
        $context = New-TerraformAcceptanceContext `
            -Source (Join-Path $script:repoRoot 'tests' 'fixtures' 'modules' $Fixture) `
            -Name $Fixture -Overlay (Join-Path $migration 'input')
        try {
            $expected = $context.Authored.Clone()
            $golden = Get-TerraformAcceptanceFiles -Root (Join-Path $migration 'expected')
            $golden.Count | Should -BeGreaterThan 0
            foreach ($path in $golden.Keys) { $expected[$path] = $golden[$path] }

            $null = Invoke-TerraformAcceptancePreCommit -Context $context
            Assert-TerraformAcceptanceFiles -Context $context -Expected $expected
            $first = Get-TerraformAcceptanceFiles -Root $context.Root -Authored $expected `
                -ConfigurationDirectories $context.ConfigurationDirectories

            $null = Invoke-TerraformAcceptancePreCommit -Context $context
            Assert-TerraformAcceptanceFiles -Context $context -Expected $first
            $null = Invoke-TerraformAcceptanceUnit -Context $context -Runs 4
            Assert-TerraformAcceptanceFiles -Context $context -Expected $first

            $lock = Join-Path $context.Root '.terraform.lock.hcl'
            Test-Path -LiteralPath $lock | Should -BeTrue
            $first['.terraform.lock.hcl'] = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash
            $null = Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments (
                @('add', '--force', '--') + @($first.Keys)
            )
            $null = Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @(
                'commit', '--quiet', '-m', 'test: reviewed utility migration',
                '-m', 'Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>'
            )
            $null = Invoke-TerraformAcceptancePrCheck -Context $context
            Assert-TerraformAcceptanceFiles -Context $context -Expected $first
            (Invoke-TerraformAcceptanceGit -Root $context.Root -Arguments @('status', '--porcelain')).StdOut |
                Should -BeNullOrEmpty
        }
        finally { Remove-TerraformAcceptanceContext -Context $context }
    }
}

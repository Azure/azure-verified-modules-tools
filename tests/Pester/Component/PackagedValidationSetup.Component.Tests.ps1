#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: packaged validation setup' -Tag Component {
    It 'reports a missing package without a secondary cleanup failure' {
        $directory = Join-Path $TestDrive 'consumer' 'tests' 'Pester' 'Integration'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $suite = Join-Path $directory 'BicepPackagedPolicy.Integration.Tests.ps1'
        Copy-Item -LiteralPath (Join-Path $script:repoRoot 'tests' 'Pester' 'Integration' `
                'BicepPackagedPolicy.Integration.Tests.ps1') -Destination $suite
        $summary = InModuleScope Avm.Authoring -Parameters @{ Suite = $suite; Directory = $directory } {
            param($Suite, $Directory)
            Invoke-AvmBicepPesterSuite -Mode Unit -Files @($Suite) -WorkingDirectory $Directory `
                -Tag Integration -TimeoutSec 60
        }
        $summary.Passed | Should -Be 0
        $setup = @($summary.Issues | Where-Object { $_.Code -eq 'avm.bicep.pester-setup-failed' })
        $setup | Should -HaveCount 1
        $setup[0].Message | Should -Match 'Run .*build\.ps1 build'
        @($summary.Issues | Where-Object { $_.Message -match 'savedEnvironment|AfterAll' }) |
            Should -HaveCount 0
    }
}

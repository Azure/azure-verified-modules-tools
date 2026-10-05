#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $script:repoRoot 'src' 'Avm.Authoring' 'Avm.Authoring.psd1') -Force
}

Describe 'Component: native Bicep convention diagnostics' -Tag Component {
    It 'maps native assertion locations and never downgrades runtime failures or skips' {
        $suite = Join-Path $TestDrive 'native.Tests.ps1'
        Set-Content -LiteralPath $suite -Encoding utf8NoBOM -Value @'
param($Convention)
Describe 'native diagnostics' -ForEach @(@{ IssuePath = (Join-Path $Convention.Root 'main.bicep') }) {
    It 'reports an advisory' -Tag 'avm.bicep.sample-warning', 'severity:warning' {
        $false | Should -BeTrue
    }
    It 'reports a metadata assertion' -Tag 'avm.bicep.sample-metadata', 'file:metadata.json' {
        'actual' | Should -BeExactly 'expected'
    }
    It 'reports a runtime failure' -Tag 'avm.bicep.sample-runtime', 'severity:warning' {
        throw [System.InvalidOperationException]::new('runtime failure')
    }
    It 'reports an unexpected skip' -Tag 'avm.bicep.sample-skip', 'severity:warning' -Skip {}
}
'@
        $summary = InModuleScope 'Avm.Authoring' -Parameters @{ Suite = $suite; Root = $TestDrive } {
            param($Suite, $Root)
            Invoke-AvmBicepPesterSuite -Mode Convention -Files @($Suite) -WorkingDirectory $Root `
                -ConventionData @{ Root = $Root } -EnvVars @{} -InProcess
        }
        $summary.Total | Should -Be 4
        $summary.Failed | Should -Be 3
        $summary.Skipped | Should -Be 1
        $summary.Issues.Count | Should -Be 4
        foreach ($issue in $summary.Issues) {
            $issue.NativeConvention | Should -BeTrue
            $issue.Severity | Should -Be $(if ($issue.Code -eq 'avm.bicep.sample-warning') { 'warning' } else { 'error' })
            $issue.File | Should -Be (Join-Path $TestDrive $(if ($issue.Code -eq 'avm.bicep.sample-metadata') { 'metadata.json' } else { 'main.bicep' }))
            $issue.Message | Should -Match 'native diagnostics'
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep post-deployment Pester data contract' -Tag Component {
    BeforeEach {
        $script:caseDirectory = Join-Path $TestDrive ('bicep assertions ' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:caseDirectory -Force
        $script:testPath = Join-Path $script:caseDirectory 'deployed.Tests.ps1'
    }

    It 'runs an authored assertion in a child with the legacy deployment data shape' {
        Set-Content -LiteralPath $script:testPath -Encoding utf8NoBOM -Value @'
param($TestInputData)
Describe 'deployed example' {
    It 'receives outputs and the absolute example directory' {
        $global:AvmBicepE2eChildMarker = 'child-only'
        $TestInputData.DeploymentOutputs.account.value | Should -Be 'account-created'
        $TestInputData.ModuleTestFolderPath | Should -Be $PSScriptRoot
    }
}
'@
        $data = @{
            DeploymentOutputs    = @{ account = @{ type = 'String'; value = 'account-created' } }
            ModuleTestFolderPath = $script:caseDirectory
        }
        $summary = InModuleScope 'Avm.Authoring' -Parameters @{
            Suite = $script:testPath; Dir = $script:caseDirectory; Data = $data
        } {
            param($Suite, $Dir, $Data)
            Invoke-AvmBicepPesterSuite -Mode E2e -Files @($Suite) `
                -TestInputData $Data -WorkingDirectory $Dir -TimeoutSec 30
        }

        $summary.Total | Should -Be 1
        $summary.Passed | Should -Be 1
        $summary.Failed | Should -Be 0
        $summary.Issues | Should -BeNullOrEmpty
        Get-Variable -Name AvmBicepE2eChildMarker -Scope Global -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty
    }

    It 'returns detailed assertion failures and skips from the real child process' {
        Set-Content -LiteralPath $script:testPath -Encoding utf8NoBOM -Value @'
param($TestInputData)
Describe 'deployed example' {
    It 'fails its authored assertion' {
        $TestInputData.DeploymentOutputs.account.value | Should -Be 'another-account'
    }
    It 'skips another assertion' -Skip { $true | Should -BeTrue }
}
'@
        $data = @{
            DeploymentOutputs    = @{ account = @{ type = 'String'; value = 'account-created' } }
            ModuleTestFolderPath = $script:caseDirectory
        }
        $summary = InModuleScope 'Avm.Authoring' -Parameters @{
            Suite = $script:testPath; Dir = $script:caseDirectory; Data = $data
        } {
            param($Suite, $Dir, $Data)
            Invoke-AvmBicepPesterSuite -Mode E2e -Files @($Suite) `
                -TestInputData $Data -WorkingDirectory $Dir -TimeoutSec 30
        }

        $summary.Total | Should -Be 2
        $summary.Passed | Should -Be 0
        $summary.Failed | Should -Be 1
        $summary.Skipped | Should -Be 1
        $summary.Issues.Code | Should -Contain 'avm.bicep.pester-failed'
        $summary.Issues.Code | Should -Contain 'avm.bicep.pester-skipped'
        ($summary.Issues | Where-Object { $_.Code -eq 'avm.bicep.pester-failed' }).Message |
            Should -Match 'another-account'
    }

    It 'surfaces a broken authored suite as a Pester setup error' {
        Set-Content -LiteralPath $script:testPath -Encoding utf8NoBOM -Value @'
throw [System.Exception]::new('Authored suite failed to load.')
'@
        $data = @{
            DeploymentOutputs    = $null
            ModuleTestFolderPath = $script:caseDirectory
        }
        $summary = InModuleScope 'Avm.Authoring' -Parameters @{
            Suite = $script:testPath; Dir = $script:caseDirectory; Data = $data
        } {
            param($Suite, $Dir, $Data)
            Invoke-AvmBicepPesterSuite -Mode E2e -Files @($Suite) `
                -TestInputData $Data -WorkingDirectory $Dir -TimeoutSec 30
        }

        $summary.Passed | Should -Be 0
        $summary.Issues.Code | Should -Contain 'avm.bicep.pester-setup-failed'
        $summary.Issues.Message | Should -Match 'Authored suite failed to load'
    }
}

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
    It 'reports a metadata assertion' -ForEach @(@{ IssueLine = 17; IssueRoot = $Convention.Root }) -Tag 'avm.bicep.sample-metadata', 'file:metadata.json' {
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
            $issue.Line | Should -Be $(if ($issue.Code -eq 'avm.bicep.sample-metadata') { 17 } else { 1 })
            if ($issue.Code -eq 'avm.bicep.sample-metadata') { $issue.IssueRoot | Should -Be ([string]$TestDrive) }
        }
    }
}

AfterAll {
    Remove-Module Avm.Authoring -Force -ErrorAction SilentlyContinue
}

Describe 'Component: Bicep authored unit Pester semantics' -Tag Component {
    It 'matches direct Pester for <Mode> while preserving authored strictness and non-passing results' -ForEach @(
        @{ Mode = 'Unit' }
        @{ Mode = 'unit' }
        @{ Mode = 'UNIT' }
    ) {
        $suite = Join-Path $TestDrive 'authored-unit.Tests.ps1'
        $directRunner = Join-Path $TestDrive 'direct-pester.ps1'
        Set-Content -LiteralPath $suite -Encoding utf8NoBOM -Value @'
Describe 'authored unit behavior' {
    It 'filters optional dictionary properties' {
        $subnets = @(@{ name = 'private-endpoints' }, @{ name = 'gateway'; delegation = 'value' })
        @($subnets | Where-Object delegation -CEQ 'value').Count | Should -Be 1
    }
    It 'reads a property from an empty array' {
        $before = @()
        $after = @(@{ digest = 'sha256:1' })
        $created = @($after | Where-Object { $_.digest -cnotin @($before.digest) })
        $created.Count | Should -Be 1
    }
    It 'honors strict mode selected by the author' {
        Set-StrictMode -Version 3.0
        $before = @()
        $before.digest
    }
    It 'surfaces an authored nonterminating error' {
        Write-Error 'authored failure'
    }
    It 'surfaces a skip' -Skip {}
    It 'surfaces an inconclusive result' {
        Set-ItResult -Inconclusive -Because 'not established'
    }
}
'@
        Set-Content -LiteralPath $directRunner -Encoding utf8NoBOM -Value @'
param([string] $Suite, [string] $PesterPath)
$ErrorActionPreference = 'Stop'
Import-Module -Name $PesterPath -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = @($Suite)
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $configuration
@{
    Version = [string]$result.Version
    Total = $result.TotalCount
    Passed = $result.PassedCount
    Failed = $result.FailedCount
    Skipped = $result.SkippedCount
    Inconclusive = $result.InconclusiveCount
} | ConvertTo-Json -Compress
'@
        $results = InModuleScope 'Avm.Authoring' -Parameters @{
            Suite = $suite; DirectRunner = $directRunner; Root = $TestDrive; Mode = $Mode
        } {
            param($Suite, $DirectRunner, $Root, $Mode)
            $pester = Import-AvmPowerShellModule -Name Pester -ModuleRoot $Root
            $direct = Invoke-AvmProcess -FilePath ([System.Environment]::ProcessPath) `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $DirectRunner, $Suite,
                    (Join-Path $pester.ModuleBase 'Pester.psd1')) -WorkingDirectory $Root
            @{
                Direct = $direct.StdOut | ConvertFrom-Json -AsHashtable
                Unit = Invoke-AvmBicepPesterSuite -Mode $Mode -Files @($Suite) `
                    -WorkingDirectory $Root -EnvVars @{} -TimeoutSec 30
            }
        }
        $results.Direct.Version | Should -Be '5.7.1'
        $results.Direct.Total | Should -Be 6
        $results.Direct.Passed | Should -Be 2
        $results.Direct.Failed | Should -Be 2
        $results.Direct.Skipped | Should -Be 1
        $results.Direct.Inconclusive | Should -Be 1
        foreach ($name in @('Version', 'Total', 'Passed', 'Failed', 'Skipped', 'Inconclusive')) {
            $results.Unit[$name] | Should -Be $results.Direct[$name]
        }
        $results.Unit.Issues.Count | Should -Be 4
        @($results.Unit.Issues | Where-Object Code -eq 'avm.bicep.pester-failed').Count | Should -Be 2
        $results.Unit.Issues.Code | Should -Contain 'avm.bicep.pester-skipped'
        $results.Unit.Issues.Code | Should -Contain 'avm.bicep.pester-inconclusive'
        ($results.Unit.Issues.Message -join "`n") | Should -Match 'authored failure'
        ($results.Unit.Issues.Message -join "`n") | Should -Match "property 'digest'"
    }
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

    It 'retains strict mode for post-deployment assertions' {
        Set-Content -LiteralPath $script:testPath -Encoding utf8NoBOM -Value @'
param($TestInputData)
Describe 'deployed example' {
    It 'fails on a missing property under runner strict mode' {
        $before = @()
        $before.digest
    }
}
'@
        $summary = InModuleScope 'Avm.Authoring' -Parameters @{
            Suite = $script:testPath; Dir = $script:caseDirectory
        } {
            param($Suite, $Dir)
            Invoke-AvmBicepPesterSuite -Mode E2e -Files @($Suite) `
                -TestInputData @{} -WorkingDirectory $Dir -TimeoutSec 30
        }

        $summary.Total | Should -Be 1
        $summary.Failed | Should -Be 1
        $summary.Issues.Code | Should -Contain 'avm.bicep.pester-failed'
        $summary.Issues.Message | Should -Match "property 'digest'"
    }
}

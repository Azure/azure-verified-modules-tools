#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $InstallRoot,

    [Parameter(Mandatory)]
    [string] $ModuleVersion,

    [Parameter(Mandatory)]
    [string] $ReportPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$env:PSModulePath = $InstallRoot + [System.IO.Path]::PathSeparator + (Join-Path $PSHOME 'Modules')
$env:AVM_TEST_PACKAGE_ROOT = Join-Path -Path $InstallRoot -ChildPath 'Avm.Authoring' `
    -AdditionalChildPath $ModuleVersion
$env:AVM_NO_AUTO_INSTALL = '1'
[System.Environment]::SetEnvironmentVariable('AVM_OFFLINE', [NullString]::Value, 'Process')
$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $repoRoot -ChildPath 'tests' -AdditionalChildPath 'Pester', 'Import-AvmTestModule.ps1') `
    -SourceManifest (Join-Path -Path $repoRoot -ChildPath 'src' -AdditionalChildPath 'Avm.Authoring', 'Avm.Authoring.psd1')
$loadedPath = (Get-Module -Name 'Avm.Authoring').Path

$selectors = @(
    'Invoke-AvmPrCheck*'
    'Bicep e2e post hook subprocess*'
    'Bicep static convention checks.checks the complete root*'
    'Bicep static convention checks.fails closed when the API*'
    'Bicep static convention checks.accepts the shipped canonical scaffold*'
    'Bicep static convention checks.accepts the previously shipped telemetry*'
    'Bicep static convention checks.rejects mixed telemetry*'
    'Bicep static convention checks.rejects any description*'
    'Bicep static convention checks.requires each exact telemetry description*'
    'Bicep PSRule policy checks.runs all four baselines*'
    'Bicep PSRule policy checks.reports required failures*'
    'Component: extracted package test imports*'
    'Component: Bicep Pester unit tier*'
    'Component: Bicep isolated end-to-end deployments.*post*'
    'Component: Bicep isolated end-to-end deployments.honors WhatIf*'
    'Component: Bicep scoped end-to-end deployments.*post*'
    'Component: Bicep ARM integration tier.does not run case-local post*'
)
& (Join-Path $repoRoot 'build.ps1') test, component -TestName $selectors
& (Join-Path $repoRoot 'build.ps1') integration -TestName 'Integration: Bicep scaffold telemetry*'

$tiers = @(
    foreach ($tier in @('unit', 'component', 'integration')) {
        $resultPath = Join-Path -Path $repoRoot -ChildPath 'out' `
            -AdditionalChildPath 'test-results', "$tier.xml"
        [xml] $document = Get-Content -LiteralPath $resultPath -Raw
        $executed = @($document.SelectNodes('//test-case') | Where-Object { $_.executed -eq 'True' })
        $unexpected = @($executed | Where-Object { $_.result -cne 'Success' })
        if ($executed.Count -eq 0 -or $unexpected.Count -gt 0 -or
            [int]$document.DocumentElement.GetAttribute('failures') -ne 0 -or
            [int]$document.DocumentElement.GetAttribute('skipped') -ne 0) {
            throw [System.InvalidOperationException]::new(
                "Packaged $tier contracts must execute and pass without skips.")
        }
        [pscustomobject]@{
            Tier   = $tier
            Passed = $executed.Count
            Tests  = @($executed | ForEach-Object { [string]$_.name })
        }
    }
)
$report = [pscustomobject]@{
    Kind            = 'offline fixture contracts; mocked compiler, policy and Azure processes, not deployment qualification'
    ImportedPath    = $loadedPath
    RequiredSteps   = 'policy/convention/docs cannot skip or return uninspectable success; docs must render every selected source'
    UnitRouting     = 'real child Pester through the packaged Resources/bicep runner'
    PostHookRouting = 'fake-process success, failure, cancellation, cleanup ordering and dry-run checks'
    Tiers           = @($tiers | Where-Object { $_.Tier -ne 'integration' })
    RealScaffold    = [pscustomobject]@{
        Kind     = 'real offline pinned Bicep compilation of generated canonical/legacy scaffold and invalid description/prefix/name cases'
        Compiler = 'bicep/0.47.16'
        Results  = @($tiers | Where-Object { $_.Tier -eq 'integration' })
    }
}
[System.IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $report -Depth 8),
    [System.Text.UTF8Encoding]::new($false))

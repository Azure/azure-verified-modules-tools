<#
.SYNOPSIS
    Run one shard of a Pester tier in an isolated process.

.DESCRIPTION
    Worker entry point for the sharded `component` task in build/avm.build.ps1.
    Component tests mutate process-wide state (PATH, AVM_HOME, the current
    directory), so shards must not share a process. The build task starts one
    pwsh per shard pointing at this script with a disjoint set of test files.

    Exit codes: 0 all passed, 1 one or more failed, 2 the shard ran no tests.
#>

#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $Path,

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [string] $Tag,

    [string[]] $FullName = @()
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Import-Module -Name 'Pester' -MinimumVersion '5.5.0' -Force -ErrorAction Stop

if ($Path.Count -eq 1 -and $Path[0].Contains([System.IO.Path]::PathSeparator)) {
    $Path = $Path[0].Split([System.IO.Path]::PathSeparator, [System.StringSplitOptions]::RemoveEmptyEntries)
}

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $OutputPath
if ($FullName.Count -gt 0) {
    $config.Filter.FullName = $FullName
}
elseif ($Tag) {
    $config.Filter.Tag = @($Tag)
}

$testRunId = [guid]::NewGuid().ToString()
$env:AVM_TEST_RUN_ID = $testRunId
$env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $testRunId

$result = Invoke-Pester -Configuration $config

$selectedCount = $result.PassedCount + $result.FailedCount + $result.SkippedCount
if ($selectedCount -eq 0) {
    exit 2
}
if ($result.FailedCount -gt 0) {
    exit 1
}
exit 0

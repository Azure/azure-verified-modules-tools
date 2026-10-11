<#
.SYNOPSIS
    Run one shard of a Pester tier in an isolated process.

.DESCRIPTION
    Worker entry point for the sharded `test` and `component` tasks in
    build/avm.build.ps1. Tests mutate process-wide state (PATH, AVM_HOME, the
    current directory), so shards must not share a process. The build task
    starts one pwsh per shard pointing at this script with a disjoint set of
    test files.

    -TempPath gives the shard its own temp folder, so fixed temp names and
    TestDrive cannot collide between shards. -AvmHome isolates the AVM
    config, cache and state folders for tiers that must not share them.

    Exit codes: 0 all passed, 1 a test or test file failed, 2 the shard ran no tests.
#>

#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $Path,

    [Parameter(Mandatory)]
    [string] $OutputPath,

    [string] $Tag,

    [string[]] $ExcludeTag = @(),

    [string] $TempPath,

    [string] $AvmHome,

    [string[]] $FullName = @()
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if ($TempPath) {
    $null = [System.IO.Directory]::CreateDirectory($TempPath)
    $env:TEMP = $TempPath
    $env:TMP = $TempPath
    $env:TMPDIR = $TempPath
}
if ($AvmHome) {
    $null = [System.IO.Directory]::CreateDirectory($AvmHome)
    $env:AVM_HOME = $AvmHome
}

$manifest = Join-Path $PSScriptRoot '..' 'src' 'Avm.Authoring' 'Avm.Authoring.psd1'
$module = Import-Module -Name $manifest -PassThru -ErrorAction Stop
try {
    $null = & $module { Import-AvmPowerShellModule -Name Pester -Global }
}
finally {
    Remove-Module -ModuleInfo $module -Force
}

if ($Path.Count -eq 1 -and $Path[0].Contains([System.IO.Path]::PathSeparator)) {
    $Path = $Path[0].Split([System.IO.Path]::PathSeparator, [System.StringSplitOptions]::RemoveEmptyEntries)
}

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Output.Verbosity = if ($env:AVM_TEST_VERBOSE -eq '1') { 'Detailed' } else { 'Normal' }
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $OutputPath
if ($FullName.Count -gt 0) {
    $config.Filter.FullName = $FullName
}
elseif ($Tag) {
    $config.Filter.Tag = @($Tag)
}
if ($ExcludeTag.Count -gt 0) {
    # pwsh -File passes arrays as one comma-separated string.
    $config.Filter.ExcludeTag = @($ExcludeTag -split ',' | Where-Object { $_ })
}

$testRunId = [guid]::NewGuid().ToString()
$env:AVM_TEST_RUN_ID = $testRunId
$env:AVM_TEST_SKIP_MODULE_VERSION_CHECK = $testRunId
$env:GITHUB_ACTIONS = ''
$env:GITHUB_STEP_SUMMARY = ''

$result = Invoke-Pester -Configuration $config

$selectedCount = $result.PassedCount + $result.FailedCount + $result.SkippedCount
if ($result.FailedCount -gt 0 -or $result.FailedContainersCount -gt 0) {
    exit 1
}
if ($selectedCount -eq 0) {
    exit 2
}
exit 0

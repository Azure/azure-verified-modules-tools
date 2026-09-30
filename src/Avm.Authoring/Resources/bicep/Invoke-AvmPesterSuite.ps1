#Requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $InputPath,

    [Parameter(Mandatory)]
    [string] $ResultPath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 5.5.0 -ErrorAction Stop
$inputData = Get-Content -LiteralPath $InputPath -Raw -Encoding utf8 |
    ConvertFrom-Json -AsHashtable -ErrorAction Stop

$configuration = New-PesterConfiguration
$configuration.Run.Container = @(
    New-PesterContainer -Path ([string[]]$inputData.Files) -Data @{
        moduleFolderPaths = [string[]]$inputData.ModulePaths
        repoRootPath      = [string]$inputData.RepositoryRoot
    }
)
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'None'
if ($inputData.Tag.Count -gt 0) {
    $configuration.Filter.Tag = [string[]]$inputData.Tag
}
if ($inputData.TestName.Count -gt 0) {
    $configuration.Filter.FullName = [string[]]$inputData.TestName
}

$result = Invoke-Pester -Configuration $configuration
$issues = [System.Collections.Generic.List[object]]::new()

foreach ($test in @($result.Tests)) {
    if ($test.Result -notin @('Failed', 'Skipped', 'Inconclusive')) {
        continue
    }

    $errorRecord = @($test.ErrorRecord) | Select-Object -First 1
    $detail = if ($null -ne $errorRecord) { $errorRecord.Exception.Message } else { "Pester reported $($test.Result)." }
    $file = if ($null -ne $test.ScriptBlock) { $test.ScriptBlock.File } else { '' }
    $line = if ($null -ne $test.ScriptBlock) { $test.ScriptBlock.StartPosition.StartLine } else { 0 }
    $issues.Add([pscustomobject][ordered]@{
            File     = [string]$file
            Line     = [int]$line
            Column   = 0
            Severity = 'error'
            Code     = "avm.bicep.pester-$($test.Result.ToLowerInvariant())"
            Message  = "$($test.ExpandedPath): $detail"
        })
}

foreach ($failed in @($result.FailedContainers) + @($result.FailedBlocks)) {
    $errorRecord = @($failed.ErrorRecord) | Select-Object -First 1
    $detail = if ($null -ne $errorRecord) { $errorRecord.Exception.Message } else { 'Pester suite setup failed.' }
    $file = if ($failed.Item -is [string]) { $failed.Item } else { '' }
    $issues.Add([pscustomobject][ordered]@{
            File     = [string]$file
            Line     = 0
            Column   = 0
            Severity = 'error'
            Code     = 'avm.bicep.pester-setup-failed'
            Message  = [string]$detail
        })
}

if ($result.Result -ne 'Passed' -and $issues.Count -eq 0) {
    $issues.Add([pscustomobject][ordered]@{
            File     = ''
            Line     = 0
            Column   = 0
            Severity = 'error'
            Code     = 'avm.bicep.pester-failed'
            Message  = "Pester finished with result '$($result.Result)' without a test diagnostic."
        })
}

$summary = [pscustomobject][ordered]@{
    Version      = [string]$result.Version
    Total        = [int]$result.TotalCount
    Passed       = [int]$result.PassedCount
    Failed       = [int]$result.FailedCount
    Skipped      = [int]$result.SkippedCount
    Inconclusive = [int]$result.InconclusiveCount
    Filtered     = [int]$result.NotRunCount
    Issues       = $issues.ToArray()
}

[System.IO.File]::WriteAllText(
    $ResultPath,
    ($summary | ConvertTo-Json -Depth 8 -Compress),
    [System.Text.UTF8Encoding]::new($false))

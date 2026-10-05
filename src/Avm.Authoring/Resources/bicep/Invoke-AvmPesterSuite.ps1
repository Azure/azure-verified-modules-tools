#Requires -Version 7.4

[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $InputPath,

    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $ResultPath,

    [Parameter(Mandatory, ParameterSetName = 'Object')]
    [System.Collections.IDictionary] $InputData
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 5.5.0 -ErrorAction Stop
if ($PSCmdlet.ParameterSetName -eq 'File') {
    $inputData = Get-Content -LiteralPath $InputPath -Raw -Encoding utf8 |
        ConvertFrom-Json -AsHashtable -ErrorAction Stop
}

$containerData = switch ($inputData.Mode) {
    'Unit' {
        @{
            moduleFolderPaths = [string[]]$inputData.ModulePaths
            repoRootPath      = [string]$inputData.RepositoryRoot
        }
    }
    'E2e' {
        if ($inputData.TestInputData -isnot [System.Collections.IDictionary]) {
            throw [System.ArgumentException]::new('E2e Pester input requires TestInputData.')
        }
        $testInputData = @{}
        foreach ($name in $inputData.TestInputData.psbase.Keys) {
            $testInputData[$name] = $inputData.TestInputData[$name]
        }
        if ($testInputData['DeploymentOutputs'] -is [System.Collections.IDictionary]) {
            $outputs = [System.Collections.Generic.Dictionary[string, object]]::new(
                [System.StringComparer]::Ordinal)
            foreach ($name in $testInputData['DeploymentOutputs'].psbase.Keys) {
                $entry = $testInputData['DeploymentOutputs'][$name]
                $outputs[$name] = if ($entry -is [System.Collections.IDictionary]) {
                    [pscustomobject]$entry
                }
                else { $entry }
            }
            $testInputData['DeploymentOutputs'] = $outputs
        }
        @{ TestInputData = $testInputData }
    }
    'Convention' {
        # The suite records findings into this shared dictionary, so it must not be serialized.
        if ($PSCmdlet.ParameterSetName -ne 'Object' -or
            $inputData.Convention -isnot [System.Collections.IDictionary]) {
            throw [System.ArgumentException]::new('Convention Pester input must be passed in process with Convention data.')
        }
        @{ Convention = $inputData.Convention }
    }
    default {
        throw [System.ArgumentException]::new("Unsupported Bicep Pester mode '$($inputData.Mode)'.")
    }
}
$configuration = New-PesterConfiguration
$configuration.Run.Container = @(
    New-PesterContainer -Path ([string[]]$inputData.Files) -Data $containerData
)
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $false
$configuration.Run.Throw = $false
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

$summary = [ordered]@{
    Version      = [string]$result.Version
    Total        = [int]$result.TotalCount
    Passed       = [int]$result.PassedCount
    Failed       = [int]$result.FailedCount
    Skipped      = [int]$result.SkippedCount
    Inconclusive = [int]$result.InconclusiveCount
    Filtered     = [int]$result.NotRunCount
    Issues       = $issues.ToArray()
}

if ($PSCmdlet.ParameterSetName -eq 'File') {
    [System.IO.File]::WriteAllText(
        $ResultPath,
        ($summary | ConvertTo-Json -Depth 8 -Compress),
        [System.Text.UTF8Encoding]::new($false))
}
else {
    return $summary
}

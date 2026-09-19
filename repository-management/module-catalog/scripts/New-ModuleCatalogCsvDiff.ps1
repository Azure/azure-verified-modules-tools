#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $SourceRoot,
    [Parameter(Mandatory)][string] $GeneratedRoot,
    [Parameter(Mandatory)][string] $OutputPath,
    [string] $SummaryPath,
    [ValidateRange(1, 1000000)][int] $MaxInlineDiffBytes = 950000,
    [string] $ConfigurationPath = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'config.json')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ModuleCatalog.ps1')

function Invoke-AvmCatalogGit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string[]] $ArgumentList
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw [System.InvalidOperationException]::new('Git failed to start.')
        }
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        $standardError = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $standardOutput.GetAwaiter().GetResult()
        $errorOutput = $standardError.GetAwaiter().GetResult()
        if ($process.ExitCode -notin @(0, 1)) {
            $detail = if ($errorOutput) { $errorOutput.Trim() } else { $output.Trim() }
            throw [System.InvalidOperationException]::new("Git diff failed with exit code $($process.ExitCode): $detail")
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output   = $output.Replace("`r`n", "`n")
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-AvmCatalogMarkdownFence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $longest = 0
    foreach ($match in [regex]::Matches($Text, '`+')) {
        $longest = [Math]::Max($longest, $match.Length)
    }
    return '`' * [Math]::Max(3, $longest + 1)
}

$source = [System.IO.Path]::GetFullPath($SourceRoot)
$generated = [System.IO.Path]::GetFullPath($GeneratedRoot)
$destination = [System.IO.Path]::GetFullPath($OutputPath)
$configuration = Read-AvmCatalogConfiguration -Path $ConfigurationPath
$outputs = @($configuration.outputs | Where-Object { $_.kind -ceq 'csv' })

if (Test-Path -LiteralPath $destination) {
    throw [System.IO.IOException]::new("CSV diff output path already exists: $destination")
}

foreach ($output in $outputs) {
    $sourcePath = Join-Path $source $output.sourcePath
    $generatedPath = Join-Path $generated $output.bundlePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Source CSV was not found: $($output.sourcePath)", $sourcePath)
    }
    if (-not (Test-Path -LiteralPath $generatedPath -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("Generated CSV was not found: $($output.bundlePath)", $generatedPath)
    }
}

if (-not $PSCmdlet.ShouldProcess($destination, 'Create complete module catalog CSV diff bundle')) {
    return
}

$parent = Split-Path -Parent $destination
$staging = Join-Path $parent ('.catalog-csv-diff-' + [guid]::NewGuid().ToString('N'))
$beforeRoot = Join-Path $staging 'before'
$afterRoot = Join-Path $staging 'after'
$diffRoot = Join-Path $staging 'diff'
$null = [System.IO.Directory]::CreateDirectory($beforeRoot)
$null = [System.IO.Directory]::CreateDirectory($afterRoot)
$null = [System.IO.Directory]::CreateDirectory($diffRoot)

try {
    $results = [System.Collections.Generic.List[object]]::new()
    $combined = [System.Text.StringBuilder]::new()
    foreach ($output in $outputs) {
        $fileName = [string]$output.sourceFile
        $sourcePath = Join-Path $source $output.sourcePath
        $generatedPath = Join-Path $generated $output.bundlePath
        $beforePath = Join-Path $beforeRoot $fileName
        $afterPath = Join-Path $afterRoot $fileName
        $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($beforePath))
        $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($afterPath))
        [System.IO.File]::Copy($sourcePath, $beforePath)
        [System.IO.File]::Copy($generatedPath, $afterPath)

        $beforeRelative = "before/$fileName"
        $afterRelative = "after/$fileName"
        $arguments = @(
            '--no-pager', 'diff', '--no-index', '--text', '--no-ext-diff',
            '--no-textconv', '--no-color', '--no-renames', '--diff-algorithm=myers',
            '--unified=3', '--src-prefix=a/', '--dst-prefix=b/', '--',
            $beforeRelative, $afterRelative
        )
        $diff = Invoke-AvmCatalogGit -WorkingDirectory $staging -ArgumentList $arguments
        $numstat = Invoke-AvmCatalogGit -WorkingDirectory $staging -ArgumentList @(
            '--no-pager', 'diff', '--no-index', '--text', '--no-ext-diff',
            '--no-textconv', '--no-color', '--no-renames', '--diff-algorithm=myers',
            '--numstat', '--', $beforeRelative, $afterRelative
        )
        $added = 0
        $deleted = 0
        if ($numstat.Output) {
            $fields = @($numstat.Output.Trim().Split("`t"))
            if ($fields.Count -lt 2 -or
                -not [int]::TryParse($fields[0], [ref]$added) -or
                -not [int]::TryParse($fields[1], [ref]$deleted)) {
                throw [System.IO.InvalidDataException]::new("Git returned invalid CSV diff statistics for $fileName.")
            }
        }

        $diffPath = Join-Path $diffRoot ([System.IO.Path]::ChangeExtension($fileName, '.diff'))
        $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($diffPath))
        [System.IO.File]::WriteAllText($diffPath, $diff.Output, [System.Text.UTF8Encoding]::new($false))
        if ($diff.Output) {
            if ($combined.Length -gt 0) {
                $null = $combined.AppendLine()
            }
            $null = $combined.Append($diff.Output)
        }
        $results.Add([pscustomobject]@{
                File    = $fileName
                Changed = $diff.ExitCode -eq 1
                Added   = $added
                Deleted = $deleted
                Diff    = $diff.Output
            })
    }

    $combinedText = $combined.ToString()
    [System.IO.File]::WriteAllText(
        (Join-Path $staging 'all-csv.diff'),
        $combinedText,
        [System.Text.UTF8Encoding]::new($false)
    )

    $changed = @($results | Where-Object Changed)
    $summary = [System.Text.StringBuilder]::new()
    $null = $summary.AppendLine('# Module metadata CSV diff')
    $null = $summary.AppendLine()
    $null = $summary.AppendLine(('{0} of {1} CSV files changed. The `module-metadata-csv-diff` artifact contains the complete diff and before/after files.' -f $changed.Count, $results.Count))
    $null = $summary.AppendLine()
    $null = $summary.AppendLine('| CSV | Changed | Added | Deleted |')
    $null = $summary.AppendLine('|---|---:|---:|---:|')
    foreach ($result in $results) {
        $changedText = if ($result.Changed) { 'Yes' } else { 'No' }
        $null = $summary.AppendLine(('| `{0}` | {1} | {2} | {3} |' -f $result.File, $changedText, $result.Added, $result.Deleted))
    }

    if ($changed.Count -gt 0) {
        $inlineBytes = [System.Text.Encoding]::UTF8.GetByteCount($combinedText)
        $null = $summary.AppendLine()
        if ($inlineBytes -le $MaxInlineDiffBytes) {
            foreach ($result in $changed) {
                $fence = Get-AvmCatalogMarkdownFence -Text $result.Diff
                $null = $summary.AppendLine("<details><summary><code>$($result.File)</code> (+$($result.Added) / -$($result.Deleted))</summary>")
                $null = $summary.AppendLine()
                $null = $summary.AppendLine("${fence}diff")
                $null = $summary.Append($result.Diff)
                if (-not $result.Diff.EndsWith("`n", [StringComparison]::Ordinal)) {
                    $null = $summary.AppendLine()
                }
                $null = $summary.AppendLine($fence)
                $null = $summary.AppendLine()
                $null = $summary.AppendLine('</details>')
                $null = $summary.AppendLine()
            }
        }
        else {
            $null = $summary.AppendLine(('The complete {0:N0}-byte diff exceeds the {1:N0}-byte inline limit. Download the artifact to review it.' -f $inlineBytes, $MaxInlineDiffBytes))
        }
    }

    $summaryText = $summary.ToString().Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText(
        (Join-Path $staging 'summary.md'),
        $summaryText,
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.Directory]::Move($staging, $destination)
    if ($SummaryPath) {
        [System.IO.File]::AppendAllText(
            [System.IO.Path]::GetFullPath($SummaryPath),
            $summaryText,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    return [pscustomobject]@{
        OutputPath       = $destination
        FileCount        = $results.Count
        ChangedFileCount = $changed.Count
        AddedLineCount   = ($results | Measure-Object -Property Added -Sum).Sum
        DeletedLineCount = ($results | Measure-Object -Property Deleted -Sum).Sum
        DiffBytes        = [System.Text.Encoding]::UTF8.GetByteCount($combinedText)
    }
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}

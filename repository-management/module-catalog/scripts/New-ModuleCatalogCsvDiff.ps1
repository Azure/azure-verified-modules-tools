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

function Read-AvmCatalogCsvDiffFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $reader = [System.IO.StringReader]::new([System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true)))
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($reader)
    try {
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        $headers = $parser.ReadFields()
        if ($null -eq $headers -or $headers.Count -eq 0) {
            throw [System.IO.InvalidDataException]::new("CSV has no header: $Path")
        }
        $rows = [System.Collections.Generic.List[object]]::new()
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if ($fields.Count -ne $headers.Count) {
                throw [System.IO.InvalidDataException]::new("CSV row has $($fields.Count) fields, expected $($headers.Count): $Path")
            }
            $row = [ordered]@{}
            for ($index = 0; $index -lt $headers.Count; $index++) {
                $row[$headers[$index]] = $fields[$index]
            }
            $rows.Add($row)
        }
        return [pscustomobject]@{ Headers = $headers; Rows = $rows.ToArray() }
    }
    finally {
        $parser.Close()
        $reader.Dispose()
    }
}

function Get-AvmCatalogCsvRowDiffKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Row)

    $key = [string]$Row['ModuleName']
    if ([string]::IsNullOrWhiteSpace($key)) {
        $key = [string]$Row['RepoURL']
    }
    return $key
}

function Get-AvmCatalogCsvFieldDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $BeforePath,
        [Parameter(Mandatory)][string] $AfterPath
    )

    $before = Read-AvmCatalogCsvDiffFile -Path $BeforePath
    $after = Read-AvmCatalogCsvDiffFile -Path $AfterPath
    $beforeByKey = [ordered]@{}
    foreach ($row in $before.Rows) {
        $key = Get-AvmCatalogCsvRowDiffKey -Row $row
        if ($beforeByKey.Contains($key)) {
            $key = $key + '|' + [string]$row['RepoURL']
        }
        $beforeByKey[$key] = $row
    }
    $afterByKey = [ordered]@{}
    foreach ($row in $after.Rows) {
        $key = Get-AvmCatalogCsvRowDiffKey -Row $row
        if ($afterByKey.Contains($key)) {
            $key = $key + '|' + [string]$row['RepoURL']
        }
        $afterByKey[$key] = $row
    }

    $changed = [System.Collections.Generic.List[object]]::new()
    $added = [System.Collections.Generic.List[string]]::new()
    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $beforeByKey.Keys) {
        if (-not $afterByKey.Contains($key)) {
            $removed.Add($key)
        }
    }
    foreach ($key in $afterByKey.Keys) {
        if (-not $beforeByKey.Contains($key)) {
            $added.Add($key)
            continue
        }
        $beforeRow = $beforeByKey[$key]
        $afterRow = $afterByKey[$key]
        $fields = [System.Collections.Generic.List[object]]::new()
        foreach ($column in $after.Headers) {
            $beforeValue = if ($before.Headers -contains $column) { [string]$beforeRow[$column] } else { $null }
            $afterValue = [string]$afterRow[$column]
            if ($beforeValue -cne $afterValue) {
                $fields.Add([pscustomobject]@{ Column = $column; Before = $beforeValue; After = $afterValue })
            }
        }
        if ($fields.Count -gt 0) {
            $changed.Add([pscustomobject]@{ Key = $key; Fields = $fields.ToArray() })
        }
    }

    return [pscustomobject]@{
        Changed = $changed.ToArray()
        Added   = $added.ToArray()
        Removed = $removed.ToArray()
    }
}

function ConvertTo-AvmCatalogCsvFieldDiffMarkdown {
    [CmdletBinding()]
    param([Parameter(Mandatory)][pscustomobject] $FieldDiff)

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($FieldDiff.Added.Count -gt 0) {
        $names = ($FieldDiff.Added | ForEach-Object { "``$_``" }) -join ', '
        $null = $lines.Add(('**{0} new row(s):** {1}' -f $FieldDiff.Added.Count, $names))
        $null = $lines.Add('')
    }
    if ($FieldDiff.Removed.Count -gt 0) {
        $names = ($FieldDiff.Removed | ForEach-Object { "``$_``" }) -join ', '
        $null = $lines.Add(('**{0} removed row(s):** {1}' -f $FieldDiff.Removed.Count, $names))
        $null = $lines.Add('')
    }
    if ($FieldDiff.Changed.Count -gt 0) {
        $fieldCount = (@($FieldDiff.Changed | ForEach-Object { $_.Fields.Count }) | Measure-Object -Sum).Sum
        $null = $lines.Add(('**{0} row(s) with {1} changed field(s):**' -f $FieldDiff.Changed.Count, $fieldCount))
        $null = $lines.Add('')
        $null = $lines.Add('| Module | Field | Before | After |')
        $null = $lines.Add('|---|---|---|---|')
        foreach ($row in $FieldDiff.Changed) {
            foreach ($field in $row.Fields) {
                $beforeText = ([string]$field.Before).Replace('|', '\|').Replace("`n", '<br>')
                $afterText = ([string]$field.After).Replace('|', '\|').Replace("`n", '<br>')
                $null = $lines.Add(('| `{0}` | {1} | {2} | {3} |' -f $row.Key, $field.Column, $beforeText, $afterText))
            }
        }
        $null = $lines.Add('')
    }
    if ($lines.Count -eq 0) {
        $null = $lines.Add('_No field-level changes; rows differ only by row identity._')
    }
    return ($lines -join "`n")
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

        $fieldDiff = $null
        $fieldMarkdown = ''
        if ($diff.ExitCode -eq 1) {
            $fieldDiff = Get-AvmCatalogCsvFieldDiff -BeforePath $beforePath -AfterPath $afterPath
            $fieldMarkdown = ConvertTo-AvmCatalogCsvFieldDiffMarkdown -FieldDiff $fieldDiff
            $fieldsPath = Join-Path $diffRoot ([System.IO.Path]::ChangeExtension($fileName, '.fields.md'))
            [System.IO.File]::WriteAllText($fieldsPath, $fieldMarkdown, [System.Text.UTF8Encoding]::new($false))
        }

        $results.Add([pscustomobject]@{
                File           = $fileName
                Changed        = $diff.ExitCode -eq 1
                Added          = $added
                Deleted        = $deleted
                Diff           = $diff.Output
                FieldMarkdown  = $fieldMarkdown
                RowsChanged    = if ($fieldDiff) { $fieldDiff.Changed.Count } else { 0 }
                RowsAdded      = if ($fieldDiff) { $fieldDiff.Added.Count } else { 0 }
                RowsRemoved    = if ($fieldDiff) { $fieldDiff.Removed.Count } else { 0 }
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
    $null = $summary.AppendLine('| CSV | Changed | Rows changed | Rows added | Rows removed | Lines +/- |')
    $null = $summary.AppendLine('|---|---:|---:|---:|---:|---:|')
    foreach ($result in $results) {
        $changedText = if ($result.Changed) { 'Yes' } else { 'No' }
        $null = $summary.AppendLine(('| `{0}` | {1} | {2} | {3} | {4} | +{5}/-{6} |' -f
                $result.File, $changedText, $result.RowsChanged, $result.RowsAdded, $result.RowsRemoved, $result.Added, $result.Deleted))
    }

    if ($changed.Count -gt 0) {
        $blocks = [System.Collections.Generic.List[string]]::new()
        foreach ($result in $changed) {
            $block = [System.Text.StringBuilder]::new()
            $null = $block.AppendLine("<details><summary><code>$($result.File)</code> ($($result.RowsChanged) row(s) changed, $($result.RowsAdded) added, $($result.RowsRemoved) removed)</summary>")
            $null = $block.AppendLine()
            $null = $block.AppendLine($result.FieldMarkdown)
            $null = $block.AppendLine()
            $null = $block.AppendLine('<details><summary>Raw line diff</summary>')
            $null = $block.AppendLine()
            $fence = Get-AvmCatalogMarkdownFence -Text $result.Diff
            $null = $block.AppendLine("${fence}diff")
            $null = $block.Append($result.Diff)
            if (-not $result.Diff.EndsWith("`n", [StringComparison]::Ordinal)) {
                $null = $block.AppendLine()
            }
            $null = $block.AppendLine($fence)
            $null = $block.AppendLine()
            $null = $block.AppendLine('</details>')
            $null = $block.AppendLine()
            $null = $block.AppendLine('</details>')
            $null = $block.AppendLine()
            $blocks.Add($block.ToString())
        }
        $renderText = $blocks -join ''
        $inlineBytes = [System.Text.Encoding]::UTF8.GetByteCount($renderText)
        $null = $summary.AppendLine()
        if ($inlineBytes -le $MaxInlineDiffBytes) {
            foreach ($block in $blocks) {
                $null = $summary.Append($block)
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
        RowsChangedCount = ($results | Measure-Object -Property RowsChanged -Sum).Sum
        RowsAddedCount   = ($results | Measure-Object -Property RowsAdded -Sum).Sum
        RowsRemovedCount = ($results | Measure-Object -Property RowsRemoved -Sum).Sum
        DiffBytes        = [System.Text.Encoding]::UTF8.GetByteCount($combinedText)
    }
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}

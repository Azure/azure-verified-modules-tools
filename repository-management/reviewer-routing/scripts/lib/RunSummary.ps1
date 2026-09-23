#Requires -Version 7.4

# Log and GitHub Actions job summary output shared by the Bicep
# repository-management sweeps.

function Format-AvmRunSummaryList {
    <#
    .SYNOPSIS
    Joins values for a log line or job summary cell.

    .PARAMETER Limit
    Shows at most this many values, followed by "and N more".

    .PARAMETER AsCode
    Formats each value as a Markdown code span that is safe in a table cell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] [AllowEmptyCollection()] [object[]] $Values = @(),
        [ValidateRange(1, [int]::MaxValue)] [int] $Limit = [int]::MaxValue,
        [switch] $AsCode,
        [string] $Empty = 'none'
    )

    $items = @($Values | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return $Empty
    }

    $shown = @($items | Select-Object -First $Limit)
    if ($AsCode) {
        $shown = @($shown | ForEach-Object { '`' + $_.Replace('`', "'").Replace('|', '\|') + '`' })
    }
    $text = $shown -join ', '
    if ($items.Count -gt $shown.Count) {
        $text += " and $($items.Count - $shown.Count) more"
    }
    return $text
}

function Write-AvmRunSummary {
    <#
    .SYNOPSIS
    Writes a sweep's closing summary to the log and, in GitHub Actions, to the
    job summary.

    .DESCRIPTION
    The job summary is also written in WhatIf mode, because it only reports
    what the sweep did or would do.

    .PARAMETER Overview
    One sentence of totals, such as "3 pull request(s) checked: 1 updated".

    .PARAMETER LogLines
    Plain-text detail lines for the log.

    .PARAMETER TableRows
    Job summary table rows. Each row is an array of Markdown cells matching
    TableHeaders.

    .PARAMETER Failures
    Plain-text failure messages, listed in the job summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Overview,
        [AllowEmptyCollection()] [string[]] $LogLines = @(),
        [AllowEmptyCollection()] [string[]] $TableHeaders = @(),
        [AllowEmptyCollection()] [object[]] $TableRows = @(),
        [AllowEmptyCollection()] [string[]] $Failures = @(),
        [switch] $DryRun
    )

    $dryRunNote = if ($DryRun) { ' (dry run, nothing changed)' } else { '' }
    Write-Host "$Title summary$($dryRunNote): $Overview"
    foreach ($line in $LogLines) {
        Write-Host "  $line"
    }

    $summaryPath = $env:GITHUB_STEP_SUMMARY
    if ([string]::IsNullOrWhiteSpace($summaryPath)) {
        return
    }

    $markdown = [System.Collections.Generic.List[string]]::new()
    $markdown.Add("### $Title$dryRunNote")
    $markdown.Add('')
    $markdown.Add($Overview)
    if ($TableRows.Count -gt 0) {
        $markdown.Add('')
        $markdown.Add("| $($TableHeaders -join ' | ') |")
        $markdown.Add("| $(@($TableHeaders | ForEach-Object { '---' }) -join ' | ') |")
        foreach ($row in $TableRows) {
            $markdown.Add("| $(@($row) -join ' | ') |")
        }
    }
    if ($Failures.Count -gt 0) {
        $markdown.Add('')
        $markdown.Add('Failures:')
        $markdown.Add('')
        foreach ($failure in $Failures) {
            $text = ($failure -replace '\s+', ' ').Trim().Replace('`', "'")
            $markdown.Add("- ``$text``")
        }
    }
    $markdown.Add('')
    Add-Content -LiteralPath $summaryPath -Value $markdown -Encoding utf8NoBOM -WhatIf:$false
}

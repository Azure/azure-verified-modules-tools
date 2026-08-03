function Get-AvmSeverityWeight {
    <#
    .SYNOPSIS
        Order a diagnostic severity so an error outranks a warning, which
        outranks an informational note.

    .DESCRIPTION
        Engines emit severities in their own casing and vocabulary - tflint
        reports 'notice', which the renderer shows as 'info' - so the comparison
        is case-insensitive and scores 'notice' and 'info' as the same tier. An
        unrecognised or absent severity scores between error and info rather
        than at either end, so an engine that introduces a new name can neither
        silently outrank a real error nor lose to a nit.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [object] $Severity
    )

    Set-StrictMode -Version 3.0

    $text = ([string]$Severity).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 2
    }

    switch ($text.ToLowerInvariant()) {
        'error' { return 3 }
        'warning' { return 2 }
        'warn' { return 2 }
        'info' { return 1 }
        'information' { return 1 }
        'notice' { return 1 }
        default { return 2 }
    }
}

function Get-AvmIssueSeverityWeight {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [object] $Issue
    )

    Set-StrictMode -Version 3.0

    if ($null -eq $Issue) {
        return 2
    }

    $severityProperty = $Issue.PSObject.Properties['Severity']
    if ($null -eq $severityProperty) {
        return 2
    }

    return (Get-AvmSeverityWeight -Severity $severityProperty.Value)
}

function Get-AvmPrimaryIssue {
    <#
    .SYNOPSIS
        Pick the single most actionable issue on a result.

    .DESCRIPTION
        A failing result often carries a bare status issue (for example
        terraform's "test run 'apply' fail", which has no line number) ahead of
        the diagnostic that names the file, position and cause. The headline a
        user sees - the console summary, the GitHub Actions annotation and the
        terminating error message - must be the one that points at the problem,
        so an issue carrying a line number wins over one that does not.

        Every issue here describes the same step failing, so position dominates:
        the bare status issue is a restatement of the diagnostic beneath it, not
        a separate problem, and it must lose even when it is scored the more
        severe of the two. Severity only breaks ties between equally positioned
        issues - tflint reports an 'info' nit and the 'warning' that actually
        failed the step both with a line, and naming the nit as the reason the
        step failed states a cause that is not the cause.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $issuesProperty = $Result.PSObject.Properties['Issues']
    if ($null -eq $issuesProperty) {
        return $null
    }

    $issues = @(@($issuesProperty.Value) | Where-Object { $null -ne $_ })
    if ($issues.Count -eq 0) {
        return $null
    }

    $best = $null
    $bestScore = -1
    foreach ($issue in $issues) {
        $lineProperty = $issue.PSObject.Properties['Line']
        $positioned = $null -ne $lineProperty -and [int]$lineProperty.Value -gt 0

        # Position outranks severity outright, so the weights cannot overlap.
        $score = (Get-AvmIssueSeverityWeight -Issue $issue)
        if ($positioned) {
            $score += 10
        }

        if ($score -gt $bestScore) {
            $best = $issue
            $bestScore = $score
        }
    }

    return $best
}

function Get-AvmIssuePosition {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $Issue
    )

    Set-StrictMode -Version 3.0

    if ($null -eq $Issue) {
        return $null
    }

    $fileProperty = $Issue.PSObject.Properties['File']
    if ($null -eq $fileProperty -or [string]::IsNullOrWhiteSpace([string]$fileProperty.Value)) {
        return $null
    }

    $lineProperty = $Issue.PSObject.Properties['Line']
    $columnProperty = $Issue.PSObject.Properties['Column']

    return @{
        File   = [string]$fileProperty.Value
        Line   = if ($null -ne $lineProperty) { [int]$lineProperty.Value } else { 0 }
        Column = if ($null -ne $columnProperty) { [int]$columnProperty.Value } else { 0 }
    }
}

function Get-AvmPrimaryIssueLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $chosen = Get-AvmPrimaryIssue -Result $Result
    if ($null -eq $chosen) {
        return ''
    }

    $lines = @(ConvertTo-AvmIssueLine -Result ([pscustomobject]@{ Issues = @($chosen) }))
    if ($lines.Count -gt 0) {
        return $lines[0]
    }

    return ''
}

function Get-AvmStepPosition {
    <#
    .SYNOPSIS
        Locate the position carried by a single failing step's headline
        diagnostic, or null when it has none.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $Step
    )

    Set-StrictMode -Version 3.0

    if ($null -eq $Step) {
        return $null
    }

    $errorProperty = $Step.PSObject.Properties['Error']
    if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
        return $null
    }

    $resultProperty = $Step.PSObject.Properties['Result']
    if ($null -ne $resultProperty -and $null -ne $resultProperty.Value) {
        return (Get-AvmIssuePosition -Issue (Get-AvmPrimaryIssue -Result $resultProperty.Value))
    }

    return $null
}

function Get-AvmStepSeverityWeight {
    <#
    .SYNOPSIS
        Score how severe a failing step's headline problem is.

    .DESCRIPTION
        A step whose tool broke outright carries an Error string and no issues,
        and is scored as an error: the check did not run, which is at least as
        serious as one that ran and reported. Otherwise the score comes from the
        headline diagnostic, so a step is ranked by the same issue whose text is
        printed for it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [object] $Step
    )

    Set-StrictMode -Version 3.0

    if ($null -eq $Step) {
        return 2
    }

    $errorProperty = $Step.PSObject.Properties['Error']
    if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
        return (Get-AvmSeverityWeight -Severity 'error')
    }

    $resultProperty = $Step.PSObject.Properties['Result']
    if ($null -ne $resultProperty -and $null -ne $resultProperty.Value) {
        $issue = Get-AvmPrimaryIssue -Result $resultProperty.Value
        if ($null -ne $issue) {
            return (Get-AvmIssueSeverityWeight -Issue $issue)
        }
    }

    $statusProperty = $Step.PSObject.Properties['Status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -eq 'error') {
        return (Get-AvmSeverityWeight -Severity 'error')
    }

    return 2
}

function Get-AvmStepRank {
    <#
    .SYNOPSIS
        Score a failing step by how serious its headline diagnostic is, then by
        how precisely it points at the problem.

    .DESCRIPTION
        Steps in one run are separate problems, so severity decides between them
        first: a run carrying formatting drift, a lint nit and a broken test
        must headline the test, not the nit, even though both name a line. This
        is the opposite weighting to Get-AvmPrimaryIssue, which chooses between
        issues describing a single failure and so must let position dominate.

        Precision breaks ties within a severity. A file on its own is not the
        same as a file and a line - terraform's formatting drift names the file
        it would rewrite but has no position inside it, so an annotation built
        from it lands on the file header rather than on any code. The line test
        matches Get-AvmPrimaryIssue's, so a step is ranked by the same measure
        used to choose between the issues within it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]
        [object] $Step
    )

    Set-StrictMode -Version 3.0

    $precision = 0
    $position = Get-AvmStepPosition -Step $Step
    if ($null -ne $position) {
        $precision = if ([int]$position.Line -gt 0) { 2 } else { 1 }
    }

    # Severity outranks precision outright, so the weights cannot overlap.
    return ((Get-AvmStepSeverityWeight -Step $Step) * 10) + $precision
}

function Get-AvmFailureStep {
    <#
    .SYNOPSIS
        Pick the failing step whose diagnostic should headline the run.

    .DESCRIPTION
        F58: a chain reports every failing step rather than stopping at the
        first, so pipeline order says nothing about which failure is the most
        actionable. One stray space fails format, transform, lint and docs at
        once, and taking the first of those headlines formatting drift while a
        broken test later in the same run - carrying the only file, line and
        column in it - never reaches the single GitHub Actions annotation. The
        developer then sees a nit in the Files-changed view and nothing about
        the test.

        The step whose headline diagnostic is the most serious therefore wins,
        with precision breaking ties within a severity. Order still decides
        between steps that tie on both, so a run whose failures are equally
        serious and equally precise reports exactly as it did before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $stepsProperty = $Result.PSObject.Properties['Steps']
    if ($null -eq $stepsProperty) {
        return $null
    }

    $failing = @(@($stepsProperty.Value) | Where-Object {
            $null -ne $_ -and [string]$_.Status -in @('fail', 'error')
        })
    if ($failing.Count -eq 0) {
        return $null
    }

    $best = $failing[0]
    $bestRank = Get-AvmStepRank -Step $best
    foreach ($step in $failing) {
        $rank = Get-AvmStepRank -Step $step
        if ($rank -gt $bestRank) {
            $best = $step
            $bestRank = $rank
        }
    }

    return $best
}

function Get-AvmFailureDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $step = Get-AvmFailureStep -Result $Result
    if ($null -ne $step) {
        $errorProperty = $step.PSObject.Properties['Error']
        if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
            return "Step '$($step.Step)': $($errorProperty.Value)"
        }
        $resultProperty = $step.PSObject.Properties['Result']
        if ($null -ne $resultProperty -and $null -ne $resultProperty.Value) {
            $issueLine = Get-AvmPrimaryIssueLine -Result $resultProperty.Value
            if (-not [string]::IsNullOrWhiteSpace($issueLine)) {
                return "Step '$($step.Step)': $issueLine"
            }
        }
        return "Step '$($step.Step)' reported Status '$($step.Status)'."
    }

    return (Get-AvmPrimaryIssueLine -Result $Result)
}

function Get-AvmFailurePosition {
    <#
    .SYNOPSIS
        Locate the file, line and column behind the detail Get-AvmFailureDetail
        returns, so the GitHub Actions annotation can be anchored on it.

    .DESCRIPTION
        Both walks start from the same Get-AvmFailureStep choice, so the
        annotation is anchored on the step whose text is being reported and a
        branch that yields a positionless detail still yields a null position.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $step = Get-AvmFailureStep -Result $Result
    if ($null -ne $step) {
        return (Get-AvmStepPosition -Step $step)
    }

    return (Get-AvmIssuePosition -Issue (Get-AvmPrimaryIssue -Result $Result))
}

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

    $preferred = $issues | Where-Object {
        $lineProperty = $_.PSObject.Properties['Line']
        $null -ne $lineProperty -and [int]$lineProperty.Value -gt 0
    } | Select-Object -First 1

    if ($null -ne $preferred) {
        return $preferred
    }

    return $issues[0]
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

function Get-AvmFailureDetail {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $stepsProperty = $Result.PSObject.Properties['Steps']
    if ($null -ne $stepsProperty) {
        foreach ($step in @($stepsProperty.Value)) {
            if ([string]$step.Status -notin @('fail', 'error')) {
                continue
            }
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
    }

    return (Get-AvmPrimaryIssueLine -Result $Result)
}

function Get-AvmFailurePosition {
    <#
    .SYNOPSIS
        Locate the file, line and column behind the detail Get-AvmFailureDetail
        returns, so the GitHub Actions annotation can be anchored on it.

    .DESCRIPTION
        The walk deliberately mirrors Get-AvmFailureDetail step for step: the
        annotation must point at the issue whose text is being reported, so a
        branch that yields a positionless detail must yield a null position.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $stepsProperty = $Result.PSObject.Properties['Steps']
    if ($null -ne $stepsProperty) {
        foreach ($step in @($stepsProperty.Value)) {
            if ([string]$step.Status -notin @('fail', 'error')) {
                continue
            }
            $errorProperty = $step.PSObject.Properties['Error']
            if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
                return $null
            }
            $resultProperty = $step.PSObject.Properties['Result']
            if ($null -ne $resultProperty -and $null -ne $resultProperty.Value) {
                return (Get-AvmIssuePosition -Issue (Get-AvmPrimaryIssue -Result $resultProperty.Value))
            }
            return $null
        }
    }

    return (Get-AvmIssuePosition -Issue (Get-AvmPrimaryIssue -Result $Result))
}

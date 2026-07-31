function Get-AvmPrimaryIssueLine {
    <#
    .SYNOPSIS
        Render the single most actionable issue on a result.

    .DESCRIPTION
        A failing result often carries a bare status issue (for example
        terraform's "test run 'apply' fail", which has no line number) ahead of
        the diagnostic that names the file, position and cause. The headline a
        user sees - the console summary, the GitHub Actions annotation and the
        terminating error message - must be the one that points at the problem,
        so an issue carrying a line number wins over one that does not.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    Set-StrictMode -Version 3.0

    $issuesProperty = $Result.PSObject.Properties['Issues']
    if ($null -eq $issuesProperty) {
        return ''
    }

    $issues = @(@($issuesProperty.Value) | Where-Object { $null -ne $_ })
    if ($issues.Count -eq 0) {
        return ''
    }

    $preferred = $issues | Where-Object {
        $lineProperty = $_.PSObject.Properties['Line']
        $null -ne $lineProperty -and [int]$lineProperty.Value -gt 0
    } | Select-Object -First 1

    $chosen = if ($null -ne $preferred) { $preferred } else { $issues[0] }

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

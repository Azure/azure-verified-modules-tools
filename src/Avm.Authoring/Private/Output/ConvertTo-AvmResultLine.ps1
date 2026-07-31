function ConvertTo-AvmResultLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [Parameter(Mandatory)]
        [string] $Verb
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $status = [string]$Result.PSObject.Properties['Status'].Value
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('avm {0}: {1}' -f $Verb, $status))

    $stepsProperty = $Result.PSObject.Properties['Steps']
    if ($null -ne $stepsProperty) {
        foreach ($step in @($stepsProperty.Value)) {
            $duration = $step.PSObject.Properties['DurationMs']
            $durationText = if ($null -ne $duration) { ' ({0} ms)' -f $duration.Value } else { '' }
            $lines.Add(('  [{0}] {1}{2}' -f $step.Status, $step.Step, $durationText))

            $errorProperty = $step.PSObject.Properties['Error']
            if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
                $lines.Add(('    {0}' -f $errorProperty.Value))
            }

            $resultProperty = $step.PSObject.Properties['Result']
            if ($null -ne $resultProperty -and $null -ne $resultProperty.Value) {
                foreach ($issueLine in @(ConvertTo-AvmIssueLine -Result $resultProperty.Value -Indent '    ')) {
                    $lines.Add($issueLine)
                }
            }
        }
    }
    else {
        foreach ($issueLine in @(ConvertTo-AvmIssueLine -Result $Result -Indent '  ')) {
            $lines.Add($issueLine)
        }
    }

    return $lines.ToArray()
}

function ConvertTo-AvmIssueLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Indent = ''
    )

    $issuesProperty = $Result.PSObject.Properties['Issues']
    if ($null -eq $issuesProperty) {
        return @()
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($issue in @($issuesProperty.Value)) {
        if ($null -eq $issue) {
            continue
        }

        $severityProperty = $issue.PSObject.Properties['Severity']
        $severity = if ($null -ne $severityProperty) { [string]$severityProperty.Value } else { 'issue' }
        $fileProperty = $issue.PSObject.Properties['File']
        $location = if ($null -ne $fileProperty) { [string]$fileProperty.Value } else { '' }
        $lineProperty = $issue.PSObject.Properties['Line']
        $columnProperty = $issue.PSObject.Properties['Column']
        if ($location -and $null -ne $lineProperty -and [int]$lineProperty.Value -gt 0) {
            $location += ':' + [string]$lineProperty.Value
            if ($null -ne $columnProperty -and [int]$columnProperty.Value -gt 0) {
                $location += ':' + [string]$columnProperty.Value
            }
        }
        if ($location) {
            $location += ' '
        }

        $codeProperty = $issue.PSObject.Properties['Code']
        $code = if ($null -ne $codeProperty -and -not [string]::IsNullOrWhiteSpace([string]$codeProperty.Value)) {
            '[{0}] ' -f $codeProperty.Value
        }
        else {
            ''
        }
        $messageProperty = $issue.PSObject.Properties['Message']
        $message = if ($null -ne $messageProperty) { [string]$messageProperty.Value } else { [string]$issue }
        $lines.Add(('{0}{1} {2}{3}{4}' -f $Indent, $severity, $location, $code, $message))
    }

    return $lines.ToArray()
}

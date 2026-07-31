function ConvertTo-AvmResultLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Result,

        [Parameter(Mandatory)]
        [string] $Verb
    )

    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'

    $items = @($Result | Where-Object { $null -ne $_ })
    $lines = [System.Collections.Generic.List[string]]::new()

    if ($items.Count -eq 0) {
        $lines.Add(('avm {0}: no results' -f $Verb))
        return $lines.ToArray()
    }

    if ($items.Count -eq 1) {
        $single = $items[0]
        $status = [string]$single.PSObject.Properties['Status'].Value
        $lines.Add(('avm {0}: {1}{2}' -f $Verb, $status, (Format-AvmTimingSuffix -InputObject $single)))
        foreach ($detail in (ConvertTo-AvmResultDetailLine -Result $single -Indent '  ')) {
            $lines.Add($detail)
        }
        return $lines.ToArray()
    }

    $lines.Add(('avm {0}: {1} results' -f $Verb, $items.Count))
    foreach ($item in $items) {
        $status = [string]$item.PSObject.Properties['Status'].Value
        $identity = Get-AvmResultIdentity -Result $item
        $label = if ([string]::IsNullOrWhiteSpace($identity)) { '' } else { ' ' + $identity }
        $lines.Add(('  [{0}]{1}{2}' -f $status, $label, (Format-AvmTimingSuffix -InputObject $item)))
        foreach ($detail in (ConvertTo-AvmResultDetailLine -Result $item -Indent '    ')) {
            $lines.Add($detail)
        }
    }

    return $lines.ToArray()
}

function Get-AvmResultIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result
    )

    foreach ($candidate in @('Name', 'Example', 'Step', 'Tool', 'File', 'Path', 'Id')) {
        $property = $Result.PSObject.Properties[$candidate]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }

    return ''
}

function ConvertTo-AvmResultDetailLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Indent = '  '
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $stepsProperty = $Result.PSObject.Properties['Steps']

    if ($null -ne $stepsProperty) {
        foreach ($step in @($stepsProperty.Value)) {
            if ($null -eq $step) { continue }
            $lines.Add(('{0}[{1}] {2}{3}' -f $Indent, $step.Status, $step.Step, (Format-AvmTimingSuffix -InputObject $step)))

            $errorProperty = $step.PSObject.Properties['Error']
            if ($null -ne $errorProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
                $lines.Add(('{0}  {1}' -f $Indent, $errorProperty.Value))
            }

            $resultProperty = $step.PSObject.Properties['Result']
            if ($null -ne $resultProperty -and $null -ne $resultProperty.Value) {
                foreach ($summaryLine in @(ConvertTo-AvmRunSummaryLine -Result $resultProperty.Value -Indent ($Indent + '  '))) {
                    $lines.Add($summaryLine)
                }
                foreach ($issueLine in @(ConvertTo-AvmIssueLine -Result $resultProperty.Value -Indent ($Indent + '  '))) {
                    $lines.Add($issueLine)
                }
            }
        }

        return $lines.ToArray()
    }

    foreach ($summaryLine in @(ConvertTo-AvmRunSummaryLine -Result $Result -Indent $Indent)) {
        $lines.Add($summaryLine)
    }

    foreach ($issueLine in @(ConvertTo-AvmIssueLine -Result $Result -Indent $Indent)) {
        $lines.Add($issueLine)
    }

    return $lines.ToArray()
}

function ConvertTo-AvmRunSummaryLine {
    <#
        .SYNOPSIS
            Renders the test-run tally ('14 runs, 14 passed, 0 failed') for
            results that carry one. File counts alone are a poor coverage
            signal; run counts expose an empty suite immediately.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [string] $Indent = ''
    )

    $totalProperty = $Result.PSObject.Properties['RunsTotal']
    if ($null -eq $totalProperty -or $null -eq $totalProperty.Value) {
        return @()
    }

    $total = [int]$totalProperty.Value
    $passedProperty = $Result.PSObject.Properties['RunsPassed']
    $failedProperty = $Result.PSObject.Properties['RunsFailed']
    $passed = if ($null -ne $passedProperty) { [int]$passedProperty.Value } else { 0 }
    $failed = if ($null -ne $failedProperty) { [int]$failedProperty.Value } else { 0 }

    return @(('{0}{1} runs, {2} passed, {3} failed' -f $Indent, $total, $passed, $failed))
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
